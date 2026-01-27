package CLIO::UI::Theme;

use strict;
use warnings;
use utf8;
use FindBin;
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
        
        # Base directories
        base_dir => $opts{base_dir} || $FindBin::Bin,
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
        user_prompt_format => '{style.user_prompt}: @RESET@',
        agent_prefix => '{style.agent_label}CLIO: @RESET@',
        system_prefix => '{style.system_message}SYSTEM: @RESET@',
        error_prefix => '{style.error_message}ERROR: @RESET@',
        banner_line1 => '{style.app_title}CLIO@RESET@ {style.app_subtitle}- Command Line Intelligence Orchestrator@RESET@',
        banner_line2 => '{style.banner_label}Session ID:@RESET@ {style.banner_value}{var.session_id}@RESET@',
        banner_line3 => '{style.banner_label}You are connected to@RESET@ {style.banner_value}{var.model}@RESET@',
        banner_line4 => '{style.banner_help}Type @RESET@{style.banner_command}"/help"@RESET@ {style.banner_help}for a list of commands.@RESET@',
        help_header => '{style.data}{var.title}@RESET@',
        help_section => '{style.data}{var.section}@RESET@',
        help_command => '{style.prompt_indicator}{var.command}@RESET@',
        thinking_indicator => '{style.dim}(thinking...)@RESET@',
        nav_next => '{style.prompt_indicator}[N]ext@RESET@',
        nav_previous => '{style.prompt_indicator}[P]revious@RESET@',
        nav_quit => '{style.prompt_indicator}[Q]uit@RESET@',
        pagination_info => '{style.dim}{var.info}@RESET@',
    };
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
