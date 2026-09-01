# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Theme;

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use File::Spec;
use File::Basename;
use CLIO::UI::ANSI;
use CLIO::Util::ConfigPath qw(get_config_dir);
use CLIO::Core::Logger qw(log_debug log_warning);
# box_char() and ui_char() are called from _resolve_char() and get_ui_char()
# on every template render. Importing them at module load removes the
# per-call `require CLIO::UI::Terminal` overhead.
use CLIO::UI::Terminal qw(box_char ui_char);

# Class-level cache of disk-loaded styles and themes. Theme objects are
# created in several places (Chat, CommandHandler, plugin code, etc.), and
# each previously re-read every .style / .theme file. Parsing is cheap but
# the file IO adds up under heavy command dispatch. Cache invalidates
# automatically when files change (mtime check) or when the cache is
# explicitly cleared via Theme->clear_cache().
my %_CACHE = (
    styles      => undef,   # hashref { name => $style }
    styles_mtime => 0,      # last full load time (epoch seconds)
    themes      => undef,
    themes_mtime => 0,
);

# Maximum age (seconds) before we re-read style/theme files. 30s catches
# edits during a live session; call Theme->clear_cache() for instant refresh.
use constant CACHE_TTL => 30;

# Required style/theme keys. Used by validate_style()/validate_theme()
# for early failure on malformed files.
my @REQUIRED_STYLE_KEYS = qw(name);
my @REQUIRED_THEME_KEYS = qw(name);


=head1 NAME

CLIO::UI::Theme - Two-layer theming system (styles + themes)

=head1 DESCRIPTION

Provides a two-layer theming system:
- STYLE = Color scheme (@-codes)
- THEME = Output templates and formats

Styles control HOW things look (colors).
Themes control WHAT gets displayed (templates, separators, layouts).

=head1 SYNOPSIS

    use CLIO::UI::Theme;
    
    my $theme_mgr = CLIO::UI::Theme->new(debug => 1);
    
    # Get colors from current style
    my $color = $theme_mgr->get_color('user_prompt');
    
    # Get template from current theme
    my $template = $theme_mgr->get_template('user_prompt_format');
    
    # Render template with style colors
    my $output = $theme_mgr->render('user_prompt_format', {});
    
    # Switch style/theme
    $theme_mgr->set_style('photon');
    $theme_mgr->set_theme('compact');

=cut

sub new {
    my ($class, %opts) = @_;
    
    # Default ANSI enabled based on NO_COLOR env var
    my $ansi_enabled = $ENV{NO_COLOR} ? 0 : 1;
    
    my $self = {
        debug => $opts{debug} || 0,
        ansi => $opts{ansi} || CLIO::UI::ANSI->new(enabled => $ansi_enabled, debug => $opts{debug}),
        
        # Current selections
        current_style => $opts{style} || 'default',
        current_theme => $opts{theme} || 'default',
        
        # Loaded style/theme data
        styles => {},
        themes => {},
        
        # Base directories - use $RealBin to resolve symlinks
        base_dir => $opts{base_dir} || $RealBin,
    };
    
    bless $self, $class;
    
    # Load all available styles and themes
    $self->load_all();
    
    return $self;
}

=head2 load_all

Load all styles and themes from disk

=cut

sub load_all {
    my ($self) = @_;
    
    $self->load_styles();
    $self->load_themes();
}

=head2 load_styles

Load all .style files from styles/ directories

=cut

sub load_styles {
    my ($self) = @_;

    # Reuse the class-level cache when fresh. Each Theme instance used to
    # re-read every .style file; parsing is cheap but the disk IO adds up.
    if (_cache_fresh('styles')) {
        $self->{styles} = _cache_get('styles');
        return;
    }

    my $styles = {};

    my @style_dirs = (
        File::Spec->catdir($self->{base_dir}, 'styles'),
        File::Spec->catdir(get_config_dir('xdg'), 'styles'),
    );

    for my $dir (@style_dirs) {
        next unless -d $dir;

        opendir(my $dh, $dir) or do {
            log_debug('Theme', "Cannot open style dir $dir: $!");
            next;
        };

        # Filter for .style files but exclude hidden files (like ._* AppleDouble)
        my @files = grep { /\.style$/ && !/^\./ } readdir($dh);
        closedir($dh);

        for my $file (@files) {
            my $path = File::Spec->catfile($dir, $file);
            my $style = $self->load_style_file($path);
            if ($style && $style->{name}) {
                $styles->{$style->{name}} = $style;
                log_debug('Theme', "Loaded style: $style->{name}");
            }
        }
    }

    # If no styles loaded, create default in memory
    unless (keys %$styles) {
        log_debug('Theme', "No styles loaded, using built-in default");
        $styles->{default} = $self->get_builtin_style();
    }

    _cache_set('styles', $styles);
    $self->{styles} = $styles;
}

=head2 load_themes

Load all .theme files from themes/ directories

=cut

sub load_themes {
    my ($self) = @_;

    if (_cache_fresh('themes')) {
        $self->{themes} = _cache_get('themes');
        return;
    }

    my $themes = {};

    my @theme_dirs = (
        File::Spec->catdir($self->{base_dir}, 'themes'),
        File::Spec->catdir(get_config_dir('xdg'), 'themes'),
    );

    for my $dir (@theme_dirs) {
        next unless -d $dir;

        opendir(my $dh, $dir) or do {
            log_debug('Theme', "Cannot open theme dir $dir: $!");
            next;
        };

        # Filter for .theme files but exclude hidden files (like ._* AppleDouble)
        my @files = grep { /\.theme$/ && !/^\./ } readdir($dh);
        closedir($dh);

        for my $file (@files) {
            my $path = File::Spec->catfile($dir, $file);
            my $theme = $self->load_theme_file($path);
            if ($theme && $theme->{name}) {
                $themes->{$theme->{name}} = $theme;
                log_debug('Theme', "Loaded theme: $theme->{name}");
            }
        }
    }

    # If no themes loaded, create default in memory
    unless (keys %$themes) {
        log_debug('Theme', "No themes loaded, using built-in default");
        $themes->{default} = $self->get_builtin_theme();
    }

    _cache_set('themes', $themes);
    $self->{themes} = $themes;
}

# ────────────────────────────────────────────────────────────────────
# Class-level disk cache helpers
# ────────────────────────────────────────────────────────────────────

sub _cache_fresh {
    my ($kind) = @_;
    return 0 unless $_CACHE{$kind};
    my $ttl_key = $kind . '_mtime';
    return (time() - $_CACHE{$ttl_key}) < CACHE_TTL;
}

sub _cache_get {
    my ($kind) = @_;
    return $_CACHE{$kind};
}

sub _cache_set {
    my ($kind, $data) = @_;
    $_CACHE{$kind} = $data;
    my $ttl_key = $kind . '_mtime';
    $_CACHE{$ttl_key} = time();
}

=head2 clear_cache

Drop the class-level cache of disk-loaded styles and themes. Useful in
tests or after editing style/theme files mid-session.

=cut

sub clear_cache {
    %_CACHE = (
        styles       => undef,
        styles_mtime => 0,
        themes       => undef,
        themes_mtime => 0,
    );
}

=head2 validate_style / validate_theme

Light structural validation. Warns (does not die) on missing required
keys or empty file - lets the loader skip the file while keeping other
styles working.

Returns: 1 if valid, 0 otherwise.

=cut

sub check_style_data {
    my ($style, $source) = @_;

    # Allow class-method invocation (`Theme->check_style_data($h)`) as well
    # as function invocation (`Theme::check_style_data($h)`). When called
    # as a class method, $style is the package name and the actual hash
    # arrives in $source.
    if (!ref($style) && ref($source) eq 'HASH') {
        ($style, $source) = ($source, '<unknown>');
    }

    return _validate_hashref($style, $source, \@REQUIRED_STYLE_KEYS, 'style');
}

sub check_theme_data {
    my ($theme, $source) = @_;

    if (!ref($theme) && ref($source) eq 'HASH') {
        ($theme, $source) = ($source, '<unknown>');
    }

    return _validate_hashref($theme, $source, \@REQUIRED_THEME_KEYS, 'theme');
}

sub _validate_hashref {
    my ($hash, $source, $required, $kind) = @_;
    $source //= '<unknown>';

    if (!defined $hash || ref($hash) ne 'HASH') {
        log_debug('Theme', "$kind file $source is not a hashref, skipping");
        return 0;
    }
    if (!keys %$hash) {
        log_debug('Theme', "$kind file $source is empty, skipping");
        return 0;
    }
    for my $key (@$required) {
        if (!defined $hash->{$key} || $hash->{$key} eq '') {
            log_debug('Theme', "$kind file $source missing required key '$key', skipping");
            return 0;
        }
    }
    return 1;
}

=head2 load_style_file

Load a single style file (simple key=value format)

=cut

sub load_style_file {
    my ($self, $path) = @_;

    return undef unless -f $path;

    open(my $fh, '<:encoding(UTF-8)', $path) or do {
        log_debug('Theme', "Cannot open style file $path: $!");
        return undef;
    };

    my $style = { file => $path };

    while (my $line = <$fh>) {
        chomp $line;

        # Skip comments and empty lines
        next if $line =~ /^\s*#/ || $line =~ /^\s*$/;

        # Parse key=value
        if ($line =~ /^(\w+)\s*=\s*(.+)$/) {
            my ($key, $value) = ($1, $2);
            $style->{$key} = $value;
        }
    }

    close($fh);

    # Apply backward-compatibility aliases. Older style files (and many
    # user-customized styles) still reference keys like 'dim', 'data',
    # 'app_title' that were renamed to canonical forms ('subtle', 'value',
    # 'primary'). Apply only when the canonical key is not already set so
    # the canonical form always wins.
    _apply_deprecated_aliases($style);

    # Structural validation. Bad files are skipped (with a log line)
    # rather than silently loaded - the previous behavior produced
    # empty $style->{name} lookups that surfaced as 'undefined color'
    # downstream and were hard to diagnose.
    return undef unless check_style_data($style, $path);

    return $style;
}

# Backward-compat alias map: deprecated_key => canonical_key.
# Loaded styles that still reference the old names get the canonical
# values transparently. The list is small and stable - new deprecations
# are documented here so a single grep finds them.
my %DEPRECATED_STYLE_ALIASES = (
    dim               => 'subtle',
    data              => 'value',
    banner            => 'app_title',
    warning_message   => 'warning',
    error_message     => 'error',
    success_message   => 'success',
    info_message      => 'info',
    banner_label      => 'label',
    banner_value      => 'value',
    banner_help       => 'label',
    banner_command    => 'command',
    app_title         => 'primary',
    app_subtitle      => 'secondary',
    command_label     => 'label',
    command_value     => 'value',
    command_header    => 'primary',
    command_subheader => 'secondary',
    highlight         => 'secondary',
    theme_header      => 'secondary',
    help_command      => 'command',
    markdown_formula  => 'secondary',
    markdown_link_text => 'link',
    markdown_link_url => 'muted',
    muted_text        => 'muted',
);

sub _apply_deprecated_aliases {
    my ($style) = @_;
    for my $deprecated (keys %DEPRECATED_STYLE_ALIASES) {
        my $canonical = $DEPRECATED_STYLE_ALIASES{$deprecated};
        next unless exists $style->{$deprecated};
        next if exists $style->{$canonical};  # canonical wins
        $style->{$canonical} = $style->{$deprecated};
    }
    return $style;
}

=head2 load_theme_file

Load a single theme file (simple key=value format)

=cut

sub load_theme_file {
    my ($self, $path) = @_;
    
    return undef unless -f $path;

    open(my $fh, '<:encoding(UTF-8)', $path) or do {
        log_debug('Theme', "Cannot open theme file $path: $!");
        return undef;
    };

    my $theme = { file => $path };

    while (my $line = <$fh>) {
        chomp $line;

        # Skip comments and empty lines
        next if $line =~ /^\s*#/ || $line =~ /^\s*$/;

        # Parse key=value
        if ($line =~ /^(\w+)\s*=\s*(.+)$/) {
            my ($key, $value) = ($1, $2);
            $theme->{$key} = $value;
        }
    }

    close($fh);

    # Structural validation (see load_style_file for rationale).
    return undef unless check_theme_data($theme, $path);

    return $theme;
}

=head2 get_color

Get a color from the current style

=cut

sub get_color {
    my ($self, $key) = @_;

    my $style = $self->_active_style();
    return '' unless $style;

    return $style->{$key} || '';
}

# Resolve the currently-active style. If current_style points to a missing
# name (e.g., user runs --style xxx where xxx doesn't exist), we used to
# silently fall through to $self->{styles}->{default}, which is also
# unreliable if the default style failed to load. This helper centralizes
# the fallback chain: explicit -> default -> built-in.
sub _active_style {
    my ($self) = @_;
    my $name = $self->{current_style};
    if ($name && exists $self->{styles}->{$name}) {
        return $self->{styles}->{$name};
    }
    if ($name && $name ne 'default') {
        log_debug('Theme', "Style '$name' not loaded, falling back to 'default'");
    }
    return $self->{styles}->{default};
}

=head2 get_spinner_frames

Get spinner animation frames from current style.

Resolves in this order:
1. spinner_frames key (legacy comma-separated explicit frames) - takes
   precedence for backward compat with custom themes.
2. spinner_style key (named spinner from CLIO::UI::Spinners) - preferred.
3. Default: 'dots'.

Capability-aware fallback: spinners that require UTF-8 (e.g., braille)
auto-fall-back to the dots spinner when the locale isn't UTF-8.

Returns an array reference of animation frames.

=cut

sub get_spinner_frames {
    my ($self) = @_;

    require CLIO::UI::Spinners;

    my $style = $self->{styles}->{$self->{current_style}} || $self->{styles}->{default};
    unless ($style) {
        return CLIO::UI::Spinners::spinner_frames('dots');
    }

    # 1. Explicit frames override (legacy / custom themes).
    if ($style->{spinner_frames}) {
        return CLIO::UI::Spinners::parse_legacy_frames($style->{spinner_frames});
    }

    # 2. Named spinner style (preferred).
    my $name = $style->{spinner_style} || 'dots';
    return CLIO::UI::Spinners::spinner_frames($name);
}

=head2 get_tool_display_format

Get tool display format from current theme: 'box' or 'inline'

Returns 'inline' (default) or 'box'

=cut

sub get_tool_display_format {
    my ($self) = @_;

    my $theme = $self->_active_theme();
    return 'inline' unless $theme;

    return $theme->{tool_display_format} || 'inline';
}

=head2 is_reduced_motion

Check if reduced motion is enabled (via style key or CLI flag).

=cut

sub is_reduced_motion {
    my ($self) = @_;
    # CLI override wins
    if ($self->{config} && $self->{config}->get('reduced_motion')) {
        return 1;
    }
    my $style = $self->{styles}->{$self->{current_style}} || $self->{styles}->{default};
    return 0 unless $style;
    return $style->{reduced_motion} ? 1 : 0;
}

=head2 is_high_contrast

Check if high contrast mode is enabled (via style key or CLI flag).

=cut

sub is_high_contrast {
    my ($self) = @_;
    # CLI override wins
    if ($self->{config} && $self->{config}->get('high_contrast')) {
        return 1;
    }
    my $style = $self->{styles}->{$self->{current_style}} || $self->{styles}->{default};
    return 0 unless $style;
    return $style->{high_contrast} ? 1 : 0;
}

# Resolve the currently-active theme. Same fallback semantics as
# _active_style() - centralized so all three call sites stay consistent.
sub _active_theme {
    my ($self) = @_;
    my $name = $self->{current_theme};
    if ($name && exists $self->{themes}->{$name}) {
        return $self->{themes}->{$name};
    }
    if ($name && $name ne 'default') {
        log_debug('Theme', "Theme '$name' not loaded, falling back to 'default'");
    }
    return $self->{themes}->{default};
}

=head2 get_ui_char($name)

Get a UI symbol, checking theme override first, then falling back to
Terminal.pm capability-aware defaults.

Theme keys: tool_bullet, tool_separator, footer_separator

    my $bullet = $theme_mgr->get_ui_char('tool_bullet');

=cut

sub get_ui_char {
    my ($self, $name) = @_;

    # Check theme override first
    my $theme = $self->_active_theme();
    if ($theme && defined $theme->{$name} && $theme->{$name} ne '') {
        return $theme->{$name};
    }

    # Map theme key names to ui_char() names
    my %key_map = (
        tool_bullet      => 'bullet',
        tool_separator   => 'separator',
        footer_separator => 'footer_sep',
    );

    my $ui_name = $key_map{$name} // $name;
    return ui_char($ui_name);
}

# Resolve {char.X} template variables to capability-aware characters
sub _resolve_char {
    my ($name) = @_;

    # Try box_char first, then ui_char
    my %box_names = map { $_ => 1 } qw(
        horizontal vertical topleft topright bottomleft bottomright
        tdown tup tleft tright cross
        dhorizontal dvertical dtopleft dtopright dbottomleft dbottomright
    );

    if ($box_names{$name}) {
        return box_char($name);
    }
    return ui_char($name);
}

=head2 get_template

Get a template from the current theme

=cut

sub get_template {
    my ($self, $key) = @_;

    my $theme = $self->_active_theme();
    return '' unless $theme;

    return $theme->{$key} || '';
}

=head2 render

Render a template by substituting {style.key} placeholders with style colors

=cut

sub render {
    my ($self, $template_key, $vars) = @_;

    $vars ||= {};

    # Inject agent_name and subtitle as default variables (host apps override via env)
    $vars->{agent_name} //= $ENV{CLIO_AGENT_NAME} || 'CLIO';
    $vars->{agent_subtitle} //= $ENV{CLIO_AGENT_SUBTITLE} || 'Command Line Intelligence Orchestrator';

    my $template = $self->get_template($template_key);
    return '' unless $template;

    # Per-render char resolution cache. Templates with many `{char.X}`
    # substitutions (e.g., long horizontal dividers) used to re-resolve
    # the same character dozens of times. Memoise on the regex match
    # variable - same lookup, cached result.
    my %char_cache;

    # Substitute {style.key} with actual style colors
    $template =~ s/\{style\.(\w+)\}/$self->get_color($1)/ge;

    # Substitute {var.key} with provided variables
    $template =~ s/\{var\.(\w+)\}/$vars->{$1} || ''/ge;

    # Substitute {char.key} with capability-aware box/UI characters
    $template =~ s/\{char\.(\w+)\}/
        exists $char_cache{$1} ? $char_cache{$1} :
        ($char_cache{$1} = _resolve_char($1))
    /ge;

    # Parse @-codes
    return $self->{ansi}->parse($template);
}

=head2 set_style

Switch to a different style

=cut

sub set_style {
    my ($self, $name) = @_;
    
    unless (exists $self->{styles}->{$name}) {
        log_debug('Theme', "Style '$name' not found");
        return 0;
    }
    
    $self->{current_style} = $name;
    log_debug('Theme', "Switched to style: $name");
    return 1;
}

=head2 set_theme

Switch to a different theme

=cut

sub set_theme {
    my ($self, $name) = @_;
    
    unless (exists $self->{themes}->{$name}) {
        log_debug('Theme', "Theme '$name' not found");
        return 0;
    }
    
    $self->{current_theme} = $name;
    log_debug('Theme', "Switched to theme: $name");
    return 1;
}

=head2 list_styles

Get list of available style names

=cut

sub list_styles {
    my ($self) = @_;
    return sort keys %{$self->{styles}};
}

=head2 list_themes

Get list of available theme names

=cut

sub list_themes {
    my ($self) = @_;
    return sort keys %{$self->{themes}};
}

=head2 get_current_style

Get current style name

=cut

sub get_current_style {
    my ($self) = @_;
    return $self->{current_style};
}

=head2 get_current_theme

Get current theme name

=cut

sub get_current_theme {
    my ($self) = @_;
    return $self->{current_theme};
}

=head2 get_pagination_hint

Get the pagination hint text for first-time display.

Args:
    streaming (bool) - If true, return simpler streaming hint

Returns: Rendered pagination hint string

=cut

sub get_pagination_hint {
    my ($self, $streaming) = @_;
    
    my $template_key = $streaming ? 'pagination_hint_streaming' : 'pagination_hint_full';
    return $self->render($template_key, {});
}

=head2 get_pagination_prompt

Get the pagination navigation prompt.

Args:
    current (int) - Current page number (1-indexed)
    total (int) - Total number of pages
    show_nav (bool) - Whether to show navigation hint (for multi-page)
    streaming (bool) - If true, use streaming variant (no page numbers)

Returns: Rendered pagination prompt string

=cut

sub get_pagination_prompt {
    my ($self, $current, $total, $show_nav, $streaming) = @_;
    
    # Streaming mode uses a simpler prompt without page numbers
    if ($streaming) {
        my $template = $self->get_template('pagination_prompt_streaming');
        if ($template && $template ne '') {
            return $self->render('pagination_prompt_streaming', {});
        }
        # Fall through to standard prompt if no streaming variant
    }
    
    my $nav_hint = '';
    if ($show_nav && $total > 1) {
        $nav_hint = $self->render('nav_hint', {}) || $self->get_color('command') . '^v' . $self->{ansi}->parse('@RESET@') . ' ';
    }
    
    return $self->render('pagination_prompt', {
        current => $current,
        total => $total,
        nav_hint => $nav_hint,
    });
}

=head2 get_confirmation_prompt

Get a themed confirmation prompt as a single inline string.

Arguments:
  - question: The question to ask (e.g., "Delete skill 'name'?")
  - options: Options display (e.g., "yes/no")
  - default_action: What pressing Enter does (e.g., "skip", "cancel")

Returns: Single rendered prompt string ready to print

=cut

sub get_confirmation_prompt {
    my ($self, $question, $options, $default_action) = @_;
    
    # Use short template when options/default are empty (free-form input)
    if (!$options && !$default_action) {
        return $self->render('confirmation_prompt_short', {
            question => $question,
        });
    }
    
    # Use no-options template when only default_action is given
    if (!$options) {
        return $self->render('confirmation_prompt_no_options', {
            question => $question,
            default_action => $default_action,
        });
    }
    
    return $self->render('confirmation_prompt', {
        question => $question,
        options => $options,
        default_action => $default_action,
    });
}

=head2 get_security_prompt

Get a themed security confirmation prompt for command/script approval.

Arguments:
  - target: The command or file path being checked
  - flags: Arrayref of flag hashrefs [{severity, description, details}, ...]
  - options: Options text (e.g., "(y)es once | (a)llow category | (n)o deny")

Returns: ($prompt_line, $input_line) - $prompt_line may contain newlines (target + flags), $input_line is the options prompt
Returns: ($prompt_line, $input_line) - two rendered strings

=cut

sub get_security_prompt {
    my ($self, $target, $flags, $options) = @_;

    # Build flag descriptions with severity colors, joined with pipe separator
    my @flag_parts;
    for my $flag (@$flags) {
        my $is_high = ($flag->{severity} eq 'high' || $flag->{severity} eq 'critical');
        my $sev_color = $is_high ? $self->get_color('error_message') : $self->get_color('warning_message');
        my $dim = $self->get_color('dim');
        push @flag_parts, "${sev_color}[$flag->{severity}]${dim} $flag->{description}\@RESET\@";
    }
    my $pipe = '@DIM@' . $self->_resolve_char('pipe') . '@RESET@';
    my $flags_str = join(" $pipe ", @flag_parts);
    $flags_str = $self->{ansi}->parse($flags_str);

    # Render the target line (full command/path, no truncation)
    my $prompt_line = $self->render('security_prompt', {
        target => $target,
    });

    # Render the input line
    my $input_line = $self->render('security_prompt_input', {
        options => $options,
    });

    # Compose multi-line output: target line, then flags line (indented)
    my $result = $prompt_line;
    $result .= "\n  " . $flags_str if @flag_parts;

    return ($result, $input_line);
}

=head2 save_style

Save current style to a new file

=cut

sub save_style {
    my ($self, $name) = @_;
    
    my $dir = File::Spec->catdir(get_config_dir('xdg'), 'styles');
    unless (-d $dir) {
        require File::Path;
        File::Path::make_path($dir) or do {
            log_debug('Theme', "Cannot create style directory: $!");
            return 0;
        };
    }
    
    my $path = File::Spec->catfile($dir, "$name.style");
    
    open(my $fh, '>:encoding(UTF-8)', $path) or do {
        log_debug('Theme', "Cannot write style file: $!");
        return 0;
    };
    
    print $fh "# CLIO Style: $name\n";
    print $fh "name=$name\n";
    
    my $style = $self->{styles}->{$self->{current_style}};
    for my $key (sort keys %$style) {
        next if $key eq 'name' || $key eq 'file';
        print $fh "$key=$style->{$key}\n";
    }
    
    close($fh);
    
    log_debug('Theme', "Saved style to: $path");
    return 1;
}

=head2 save_theme

Save current theme to a new file

=cut

sub save_theme {
    my ($self, $name) = @_;
    
    my $dir = File::Spec->catdir(get_config_dir('xdg'), 'themes');
    unless (-d $dir) {
        require File::Path;
        File::Path::make_path($dir) or do {
            log_debug('Theme', "Cannot create theme directory: $!");
            return 0;
        };
    }
    
    my $path = File::Spec->catfile($dir, "$name.theme");
    
    open(my $fh, '>:encoding(UTF-8)', $path) or do {
        log_debug('Theme', "Cannot write theme file: $!");
        return 0;
    };
    
    print $fh "# CLIO Theme: $name\n";
    print $fh "name=$name\n";
    
    my $theme = $self->{themes}->{$self->{current_theme}};
    for my $key (sort keys %$theme) {
        next if $key eq 'name' || $key eq 'file';
        print $fh "$key=$theme->{$key}\n";
    }
    
    close($fh);
    
    log_debug('Theme', "Saved theme to: $path");
    return 1;
}

=head2 get_builtin_style

Get built-in default style (fallback when no files exist)

=cut

sub get_builtin_style {
    my ($self) = @_;
    
    return {
        name => 'default',
        # ═══════════════════════════════════════════════════════════════
        # Modern Blues & Grays Theme - Cohesive, Professional
        # ═══════════════════════════════════════════════════════════════
        # Primary: Bright Cyan (main focus elements)
        # Secondary: Cyan (supporting elements)
        # Accent: Bright Green (actionable items)
        # Neutral: White/Bright White (readable text)
        # Muted: Dim White (labels, less important)
        # ═══════════════════════════════════════════════════════════════
        
        # Core message colors (conversational flow)
        user_prompt => '@BRIGHT_GREEN@',       # Accent - ready for input
        user_text => '@WHITE@',                # Neutral - readable
        agent_label => '@BRIGHT_CYAN@',        # Primary - AI speaking
        agent_text => '@WHITE@',               # Neutral - content
        system_message => '@CYAN@',            # Secondary - system info
        error_message => '@BRIGHT_RED@',       # Special - needs attention
        success_message => '@BRIGHT_GREEN@',   # Accent - positive feedback
        warning_message => '@BRIGHT_YELLOW@',  # Special - caution
        info_message => '@CYAN@',              # Secondary - informational
        
        # Banner (startup display)
        app_title => '@BOLD@@BRIGHT_CYAN@',    # Primary - main title
        app_subtitle => '@CYAN@',              # Secondary - subtitle
        banner_label => '@DIM@@WHITE@',        # Muted - labels
        banner_value => '@WHITE@',             # Neutral - values
        banner_help => '@DIM@@WHITE@',         # Muted - help text
        banner_command => '@BRIGHT_GREEN@',    # Accent - actionable
        banner => '@BRIGHT_CYAN@',             # Legacy support
        
        # Enhanced prompt (cohesive blues + green accent)
        prompt_model => '@CYAN@',              # Secondary - model info
        prompt_directory => '@BRIGHT_CYAN@',   # Primary - current location
        prompt_git_branch => '@DIM@@CYAN@',    # Muted - branch info
        prompt_indicator => '@BRIGHT_GREEN@',  # Accent - ready state
        collab_prompt => '@BRIGHT_BLUE@',      # Collaboration prompt - distinct blue
        
        # General UI elements
        theme_header => '@BRIGHT_CYAN@',       # Primary - headers
        data => '@WHITE@',                     # Neutral - data display
        dim => '@DIM@',                        # Muted - less important
        highlight => '@BRIGHT_CYAN@',          # Primary - highlighted items
        muted => '@DIM@@WHITE@',               # Muted - de-emphasized
        
        # Command output elements
        command_header => '@BOLD@@BRIGHT_CYAN@',  # Primary - command headers
        command_subheader => '@CYAN@',            # Secondary - subheaders
        command_label => '@DIM@@WHITE@',          # Muted - labels
        command_value => '@WHITE@',               # Neutral - values
        
        # Markdown styling (cohesive with theme)
        markdown_bold => '@BOLD@',
        markdown_italic => '@DIM@',
        markdown_code => '@CYAN@',                # Secondary - inline code
        markdown_formula => '@BRIGHT_CYAN@',      # Primary - formulas
        markdown_link_text => '@BRIGHT_CYAN@@UNDERLINE@',  # Primary - clickable
        markdown_link_url => '@DIM@@CYAN@',       # Muted - URLs
        markdown_header1 => '@BOLD@@BRIGHT_CYAN@', # Primary - main headers
        markdown_header2 => '@CYAN@',             # Secondary - subheaders
        markdown_header3 => '@WHITE@',            # Neutral - minor headers
        markdown_list_bullet => '@BRIGHT_GREEN@', # Accent - bullets
        markdown_quote => '@DIM@@CYAN@',          # Muted - quotes
        markdown_code_block => '@CYAN@',          # Secondary - code blocks
        
        # Help command styling
        help_command => '@BRIGHT_CYAN@',       # Commands in /help output (matches theme)
        
        # Table styling
        table_border => '@DIM@@WHITE@',        # Muted - borders
        table_header => '@BOLD@@BRIGHT_CYAN@', # Primary - headers
    };
}

=head2 get_builtin_theme

Get built-in default theme (fallback when no files exist)

=cut

sub get_builtin_theme {
    my ($self) = @_;
    
    return {
        name => 'default',
        
        # Prompts
        user_prompt_format => '{style.user_prompt}: @RESET@',
        agent_prefix => '{style.agent_label}{var.agent_name}: @RESET@',
        system_prefix => '{style.system_message}SYSTEM: @RESET@',
        error_prefix => '{style.error_message}ERROR: @RESET@',
        
        # Banner (displayed at session start)
        banner_line1 => '{style.app_title}{var.agent_name} {style.app_subtitle}- {var.agent_subtitle}@RESET@',
        banner_line2 => '{style.banner_label}Session ID: {style.data}{var.session_id}@RESET@',
        banner_line3 => '{var.session_name_line}',
        banner_line4 => '{style.banner_label}{var.routing_verb} to {style.data}{var.model}{style.banner_label}{var.route_suffix}@RESET@',

        # Help system
        help_header => '{style.data}{var.title}@RESET@',
        help_section => '{style.data}{var.section}@RESET@',
        help_command => '{style.prompt_indicator}{var.command}@RESET@',
        
        # Status indicators
        thinking_indicator => '{style.dim}(thinking...)@RESET@',
        
        # Navigation
        nav_next => '{style.prompt_indicator}[N]ext@RESET@',
        nav_previous => '{style.prompt_indicator}[P]revious@RESET@',
        nav_quit => '{style.prompt_indicator}[Q]uit@RESET@',
        pagination_info => '{style.dim}{var.info}@RESET@',
        
        # Pagination prompts (single-line format)
        pagination_hint_streaming => '',
        pagination_hint_full => '',
        pagination_prompt_streaming => '{style.dim}{char.bullet} {style.agent_label}Q{style.dim} quit {char.pipe} any key for more @RESET@',
        pagination_prompt => '{style.dim}{char.bullet} {style.data}{var.current}/{var.total} {style.dim}{char.pipe} {var.nav_hint}{style.agent_label}Q{style.dim} quit {char.pipe} any key for more @RESET@',
        
        # Confirmation prompts (single-line inline format)
        confirmation_prompt => '{style.dim}{char.bullet} {style.prompt_indicator}{var.question}{style.dim} {char.pipe} {style.data}{var.options} {style.dim}{char.pipe} {style.data}Enter{style.dim} to {style.data}{var.default_action}{style.dim}: @RESET@',
        confirmation_prompt_no_options => '{style.dim}{char.bullet} {style.prompt_indicator}{var.question}{style.dim} {char.pipe} {style.data}Enter{style.dim} to {style.data}{var.default_action}{style.dim}: @RESET@',
        confirmation_prompt_short => '{style.dim}{char.bullet} {style.prompt_indicator}{var.question}{style.dim}: @RESET@',
        
        # Security prompts (command/script approval)
        security_prompt => '{style.dim}{char.bullet} {style.warning_message}Security{style.dim} {char.pipe} {style.data}{var.target}{style.dim}@RESET@',
        security_prompt_input => '{style.dim}  {style.data}{var.options}{style.dim}: @RESET@',
        
        # Messages
        user_message_prefix => '{style.user_text}YOU: @RESET@',
        agent_message_prefix => '{style.agent_label}{var.agent_name}: @RESET@',
    };
}

=head2 validate_style

Validate that a style exists.

Arguments:
  - style_name: Style identifier

Returns:
  - (1, '') if valid
  - (0, error_message) if invalid

=cut

sub validate_style {
    my ($self, $style_name) = @_;
    
    unless (defined $style_name && length($style_name)) {
        return (0, "Style name cannot be empty");
    }
    
    if (exists $self->{styles}->{$style_name}) {
        return (1, '');
    }
    
    my @styles = $self->list_styles();
    my $styles_str = join(', ', @styles);
    return (0, "Style '$style_name' not found. Available: $styles_str");
}

=head2 validate_theme

Validate that a theme exists.

Arguments:
  - theme_name: Theme identifier

Returns:
  - (1, '') if valid
  - (0, error_message) if invalid

=cut

=head2 get_required_theme_keys

Get list of theme keys that are required for all themes.

Returns: Array of required key names

=cut

sub get_required_theme_keys {
    return qw(
        user_prompt_format
        agent_prefix
        system_prefix
        error_prefix
        banner_line1
        banner_line2
        banner_line3
        banner_line4
        help_header
        help_section
        help_command
        thinking_indicator
        nav_next
        nav_previous
        nav_quit
        pagination_info
        pagination_prompt_streaming
        pagination_prompt
        confirmation_prompt
        confirmation_prompt_no_options
        confirmation_prompt_short
        security_prompt
        security_prompt_input
        user_message_prefix
        agent_message_prefix
    );
}

=head2 is_theme_complete

Check if a theme has all required keys.

Arguments:
  - theme_name: Name of theme to check

Returns:
  - (1, '') if complete
  - (0, error_message) if incomplete, listing missing keys

=cut

sub is_theme_complete {
    my ($self, $theme_name) = @_;
    
    unless (exists $self->{themes}->{$theme_name}) {
        return (0, "Theme '$theme_name' not found");
    }
    
    my $theme = $self->{themes}->{$theme_name};
    my @required = $self->get_required_theme_keys();
    my @missing;
    
    for my $key (@required) {
        unless (exists $theme->{$key} && defined $theme->{$key} && length($theme->{$key})) {
            push @missing, $key;
        }
    }
    
    if (@missing) {
        my $missing_str = join(', ', @missing);
        return (0, "Theme '$theme_name' is incomplete. Missing keys: $missing_str");
    }
    
    return (1, '');
}

sub validate_theme {
    my ($self, $theme_name) = @_;
    
    unless (defined $theme_name && length($theme_name)) {
        return (0, "Theme name cannot be empty");
    }
    
    if (exists $self->{themes}->{$theme_name}) {
        # Theme exists - check if it's complete
        my ($complete, $error) = $self->is_theme_complete($theme_name);
        if ($complete) {
            return (1, '');
        } else {
            return (0, $error);
        }
    }
    
    my @themes = $self->list_themes();
    my $themes_str = join(', ', @themes);
    return (0, "Theme '$theme_name' not found. Available: $themes_str");
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

GPL-3.0-only

=cut

1;
