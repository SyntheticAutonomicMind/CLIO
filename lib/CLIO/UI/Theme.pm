package CLIO::UI::Theme;

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use File::Spec;
use File::Basename;
use CLIO::UI::ANSI;
use CLIO::Util::ConfigPath qw(get_config_dir);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

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
    
    my $self = {
        debug => $opts{debug} || 0,
        ansi => $opts{ansi} || CLIO::UI::ANSI->new(enabled => 1, debug => $opts{debug}),
        
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
    
    my @style_dirs = (
        File::Spec->catdir($self->{base_dir}, 'styles'),
        File::Spec->catdir(get_config_dir('xdg'), 'styles'),
    );
    
    for my $dir (@style_dirs) {
        next unless -d $dir;
        
        opendir(my $dh, $dir) or do {
            print STDERR "[DEBUG][Theme] Cannot open style dir $dir: $!\n" if $self->{debug};
            next;
        };
        
        my @files = grep { /\.style$/ } readdir($dh);
        closedir($dh);
        
        for my $file (@files) {
            my $path = File::Spec->catfile($dir, $file);
            my $style = $self->load_style_file($path);
            if ($style && $style->{name}) {
                $self->{styles}->{$style->{name}} = $style;
                print STDERR "[DEBUG][Theme] Loaded style: $style->{name}\n" if $self->{debug};
            }
        }
    }
    
    # If no styles loaded, create default in memory
    unless (keys %{$self->{styles}}) {
        print STDERR "[DEBUG][Theme] No styles loaded, using built-in default\n" if $self->{debug};
        $self->{styles}->{default} = $self->get_builtin_style();
    }
}

=head2 load_themes

Load all .theme files from themes/ directories

=cut

sub load_themes {
    my ($self) = @_;
    
    my @theme_dirs = (
        File::Spec->catdir($self->{base_dir}, 'themes'),
        File::Spec->catdir(get_config_dir('xdg'), 'themes'),
    );
    
    for my $dir (@theme_dirs) {
        next unless -d $dir;
        
        opendir(my $dh, $dir) or do {
            print STDERR "[DEBUG][Theme] Cannot open theme dir $dir: $!\n" if $self->{debug};
            next;
        };
        
        my @files = grep { /\.theme$/ } readdir($dh);
        closedir($dh);
        
        for my $file (@files) {
            my $path = File::Spec->catfile($dir, $file);
            my $theme = $self->load_theme_file($path);
            if ($theme && $theme->{name}) {
                $self->{themes}->{$theme->{name}} = $theme;
                print STDERR "[DEBUG][Theme] Loaded theme: $theme->{name}\n" if $self->{debug};
            }
        }
    }
    
    # If no themes loaded, create default in memory
    unless (keys %{$self->{themes}}) {
        print STDERR "[DEBUG][Theme] No themes loaded, using built-in default\n" if $self->{debug};
        $self->{themes}->{default} = $self->get_builtin_theme();
    }
}

=head2 load_style_file

Load a single style file (simple key=value format)

=cut

sub load_style_file {
    my ($self, $path) = @_;
    
    return undef unless -f $path;
    
    open(my $fh, '<:encoding(UTF-8)', $path) or do {
        print STDERR "[ERROR][Theme] Cannot open style file $path: $!\n";
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
    
    return $style;
}

=head2 load_theme_file

Load a single theme file (simple key=value format)

=cut

sub load_theme_file {
    my ($self, $path) = @_;
    
    return undef unless -f $path;
    
    open(my $fh, '<:encoding(UTF-8)', $path) or do {
        print STDERR "[ERROR][Theme] Cannot open theme file $path: $!\n";
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
    
    return $theme;
}

=head2 get_color

Get a color from the current style

=cut

sub get_color {
    my ($self, $key) = @_;
    
    my $style = $self->{styles}->{$self->{current_style}} || $self->{styles}->{default};
    return '' unless $style;
    
    return $style->{$key} || '';
}

=head2 get_spinner_frames

Get spinner animation frames from current style, parsed from comma-separated string

Returns an array reference of animation frames

=cut

sub get_spinner_frames {
    my ($self) = @_;
    
    my $style = $self->{styles}->{$self->{current_style}} || $self->{styles}->{default};
    return ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'] unless $style;
    
    my $frames_str = $style->{spinner_frames} || '⠋,⠙,⠹,⠸,⠼,⠴,⠦,⠧,⠇,⠏';
    
    # Split comma-separated frames
    my @frames = split(/,/, $frames_str);
    
    return \@frames;
}

=head2 get_template

Get a template from the current theme

=cut

sub get_template {
    my ($self, $key) = @_;
    
    my $theme = $self->{themes}->{$self->{current_theme}} || $self->{themes}->{default};
    return '' unless $theme;
    
    return $theme->{$key} || '';
}

=head2 render

Render a template by substituting {style.key} placeholders with style colors

=cut

sub render {
    my ($self, $template_key, $vars) = @_;
    
    $vars ||= {};
    
    my $template = $self->get_template($template_key);
    return '' unless $template;
    
    # Substitute {style.key} with actual style colors
    $template =~ s/\{style\.(\w+)\}/$self->get_color($1)/ge;
    
    # Substitute {var.key} with provided variables
    $template =~ s/\{var\.(\w+)\}/$vars->{$1} || ''/ge;
    
    # Parse @-codes
    return $self->{ansi}->parse($template);
}

=head2 set_style

Switch to a different style

=cut

sub set_style {
    my ($self, $name) = @_;
    
    unless (exists $self->{styles}->{$name}) {
        print STDERR "[ERROR][Theme] Style '$name' not found\n";
        return 0;
    }
    
    $self->{current_style} = $name;
    print STDERR "[DEBUG][Theme] Switched to style: $name\n" if $self->{debug};
    return 1;
}

=head2 set_theme

Switch to a different theme

=cut

sub set_theme {
    my ($self, $name) = @_;
    
    unless (exists $self->{themes}->{$name}) {
        print STDERR "[ERROR][Theme] Theme '$name' not found\n";
        return 0;
    }
    
    $self->{current_theme} = $name;
    print STDERR "[DEBUG][Theme] Switched to theme: $name\n" if $self->{debug};
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

Returns: Rendered pagination prompt string

=cut

sub get_pagination_prompt {
    my ($self, $current, $total, $show_nav) = @_;
    
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

=head2 get_input_prompt

Get a standardized input prompt.

Args:
    prompt (string) - The prompt text
    default_action (string, optional) - What Enter does (e.g., "skip")

Returns: Rendered input prompt string

=cut

sub get_input_prompt {
    my ($self, $prompt, $default_action) = @_;
    
    if ($default_action) {
        return $self->render('input_prompt_with_default', {
            prompt => $prompt,
            default_action => $default_action,
        });
    } else {
        return $self->render('input_prompt', {
            prompt => $prompt,
        });
    }
}

=head2 get_confirmation_prompt

Get a themed confirmation prompt with box drawing.

Arguments:
  - question: The question to ask (e.g., "Delete skill 'name'?")
  - options: Options display (e.g., "yes/no")
  - default_action: What pressing Enter does (e.g., "skip", "cancel")

Returns: Arrayref of [header, input_line] for printing separately

=cut

sub get_confirmation_prompt {
    my ($self, $question, $options, $default_action) = @_;
    
    my $header = $self->render('confirmation_header', {
        question => $question,
    });
    
    my $input = $self->render('confirmation_input', {
        options => $options,
        default_action => $default_action,
    });
    
    return [$header, $input];
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
            print STDERR "[ERROR][Theme] Cannot create style directory: $!\n";
            return 0;
        };
    }
    
    my $path = File::Spec->catfile($dir, "$name.style");
    
    open(my $fh, '>:encoding(UTF-8)', $path) or do {
        print STDERR "[ERROR][Theme] Cannot write style file: $!\n";
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
    
    print STDERR "[DEBUG][Theme] Saved style to: $path\n" if $self->{debug};
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
            print STDERR "[ERROR][Theme] Cannot create theme directory: $!\n";
            return 0;
        };
    }
    
    my $path = File::Spec->catfile($dir, "$name.theme");
    
    open(my $fh, '>:encoding(UTF-8)', $path) or do {
        print STDERR "[ERROR][Theme] Cannot write theme file: $!\n";
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
    
    print STDERR "[DEBUG][Theme] Saved theme to: $path\n" if $self->{debug};
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
        agent_prefix => '{style.agent_label}CLIO: @RESET@',
        system_prefix => '{style.system_message}SYSTEM: @RESET@',
        error_prefix => '{style.error_message}ERROR: @RESET@',
        
        # Banner (displayed at session start)
        banner_line1 => '{style.app_title}CLIO@RESET@ {style.app_subtitle}- Command Line Intelligence Orchestrator@RESET@',
        banner_line2 => '{style.banner_label}Session ID: {style.data}{var.session_id}@RESET@',
        banner_line3 => '{style.banner_label}You are connected to {style.data}{var.model}@RESET@',
        banner_line4 => '{style.banner_label}Type "{style.data}/help{style.banner_label}" for a list of commands.@RESET@',
        
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
        
        # Pagination prompts (box-drawing format with proper closures)
        pagination_hint_streaming => '{style.dim}┌──┤ Q quits | any key for more@RESET@',
        pagination_hint_full => '{style.dim}┌──┤ ^/v pages | Q quits | any key for more@RESET@',
        pagination_prompt => '{style.dim}└─┤ {style.data}{var.current}/{var.total}{style.dim} │ {var.nav_hint}Q │ >{style.dim}@RESET@',
        
        # Input prompts (standardized BBS style with box-drawing)
        input_prompt => '{style.dim}┌──┤ {style.prompt_indicator}{var.prompt}@RESET@',
        input_prompt_with_default => '{style.dim}┌──┤ {style.prompt_indicator}{var.prompt}{style.dim} | {style.data}Enter{style.dim} to {style.data}{var.default_action}@RESET@',
        
        # Confirmation prompts (box-drawing two-part format)
        confirmation_header => '{style.dim}┌──┤ {style.prompt_indicator}{var.question}@RESET@',
        confirmation_input => '{style.dim}└─┤ {style.data}{var.options}{style.dim} | {style.data}Enter{style.dim} to {style.data}{var.default_action}{style.dim}:@RESET@',
        
        # Messages
        user_message_prefix => '{style.user_text}YOU: @RESET@',
        agent_message_prefix => '{style.agent_label}CLIO: @RESET@',
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
        pagination_hint_streaming
        pagination_hint_full
        pagination_prompt
        input_prompt
        input_prompt_with_default
        confirmation_header
        confirmation_input
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

This is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

1;
