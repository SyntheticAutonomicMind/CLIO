package CLIO::Util::PathResolver;

use strict;
use warnings;
use FindBin;
use File::Spec;
use File::Path qw(make_path);

=head1 NAME

CLIO::Util::PathResolver - Centralized path resolution for CLIO

=head1 DESCRIPTION

Provides consistent path resolution for CLIO, ensuring the application
can run from any directory. Supports both development (from project dir)
and installed (in ~/.clio or system-wide) modes.

=head1 SYNOPSIS

    use CLIO::Util::PathResolver;
    
    my $sessions_dir = CLIO::Util::PathResolver::get_sessions_dir();
    my $config_file = CLIO::Util::PathResolver::get_config_file();
    my $session_file = CLIO::Util::PathResolver::get_session_file($session_id);

=cut

# Global base directory (initialized once)
our $BASE_DIR;
our $CONFIG_DIR;

=head2 init

Initialize the path resolver. Determines whether running in development
or installed mode and sets up base directories accordingly.

Call this once at application startup.

=cut

sub init {
    my (%opts) = @_;
    
    # Already initialized
    return if defined $BASE_DIR && defined $CONFIG_DIR;
    
    # Priority 1: Explicit base directory (for testing)
    if ($opts{base_dir} && -d $opts{base_dir}) {
        $BASE_DIR = $opts{base_dir};
        $CONFIG_DIR = $BASE_DIR;
        return;
    }
    
    # Priority 2: CLIO_HOME environment variable
    if ($ENV{CLIO_HOME} && -d $ENV{CLIO_HOME}) {
        $BASE_DIR = $ENV{CLIO_HOME};
        $CONFIG_DIR = $BASE_DIR;
        return;
    }
    
    # Priority 3: Check if running from development directory
    # (has lib/ and .clio/ subdirectories)
    my $script_dir = $FindBin::Bin;
    if (-d "$script_dir/lib" && -d "$script_dir/.clio") {
        # Development mode - use script directory/.clio for config
        $BASE_DIR = $script_dir;
        $CONFIG_DIR = File::Spec->catdir($script_dir, '.clio');
        return;
    }
    
    # Priority 4: Try installed mode - use ~/.clio
    my $home_dir = $ENV{HOME} || $ENV{USERPROFILE};
    if (!$home_dir) {
        # No home directory - fall back to script directory (iOS/sandboxed environment)
        $BASE_DIR = $script_dir;
        $CONFIG_DIR = File::Spec->catdir($script_dir, '.clio');
        
        # Try to create config directory
        if (!-d $CONFIG_DIR) {
            eval { make_path($CONFIG_DIR); };
            if ($@ || !-d $CONFIG_DIR) {
                warn "[WARN] Cannot create config directory $CONFIG_DIR - running in stateless mode\n";
            }
        }
        return;
    }
    
    my $home_config = File::Spec->catdir($home_dir, '.clio');
    
    # Try to create home directory config
    if (!-d $home_config) {
        eval { make_path($home_config); };
    }
    
    # Check if home config directory is usable
    if (-d $home_config && -w $home_config) {
        # Standard installed mode
        $CONFIG_DIR = $home_config;
        $BASE_DIR = $script_dir;
    } else {
        # Fall back to script directory (iOS/sandboxed environment)
        $BASE_DIR = $script_dir;
        $CONFIG_DIR = File::Spec->catdir($script_dir, '.clio');
        
        # Try to create config directory
        if (!-d $CONFIG_DIR) {
            eval { make_path($CONFIG_DIR); };
            if ($@ || !-d $CONFIG_DIR) {
                warn "[WARN] Cannot create config directory - sessions and config may not persist\n";
                # Last resort: use current directory
                $CONFIG_DIR = File::Spec->curdir();
            }
        }
    }
}

=head2 get_base_dir

Get the base directory (where the clio script and lib/ are located).

=cut

sub get_base_dir {
    init() unless defined $BASE_DIR;
    return $BASE_DIR;
}

=head2 get_config_dir

Get the configuration directory (where user data is stored).
In development: same as base dir
In installed mode: ~/.clio

=cut

sub get_config_dir {
    init() unless defined $CONFIG_DIR;
    return $CONFIG_DIR;
}

=head2 get_sessions_dir

Get the sessions directory path. Creates it if it doesn't exist.

Returns: Absolute path to sessions directory

=cut

sub get_sessions_dir {
    init() unless defined $CONFIG_DIR;
    
    my $sessions_dir = File::Spec->catdir($CONFIG_DIR, 'sessions');
    
    # Create if doesn't exist
    if (!-d $sessions_dir) {
        make_path($sessions_dir) or die "[ERROR] Cannot create sessions directory: $!\n";
    }
    
    return $sessions_dir;
}

=head2 get_session_file

Get the full path to a session file.

Arguments:
- $session_id: Session identifier

Returns: Absolute path to session file

=cut

sub get_session_file {
    my ($session_id) = @_;
    
    die "[ERROR] Session ID required\n" unless $session_id;
    
    my $sessions_dir = get_sessions_dir();
    return File::Spec->catfile($sessions_dir, "$session_id.json");
}

=head2 get_config_file

Get the full path to the main config file.

Returns: Absolute path to config file

=cut

sub get_config_file {
    init() unless defined $CONFIG_DIR;
    
    return File::Spec->catfile($CONFIG_DIR, 'config.json');
}

=head2 get_cache_dir

Get the cache directory (for URL cache, etc).

Returns: Absolute path to cache directory

=cut

sub get_cache_dir {
    init() unless defined $CONFIG_DIR;
    
    my $cache_dir = File::Spec->catdir($CONFIG_DIR, 'cache');
    
    if (!-d $cache_dir) {
        make_path($cache_dir);
    }
    
    return $cache_dir;
}

=head2 get_styles_dir

Get the styles directory path.

Returns: Absolute path to styles directory

=cut

sub get_styles_dir {
    my $base = get_base_dir();
    return File::Spec->catdir($base, 'styles');
}

=head2 get_themes_dir

Get the themes directory path.

Returns: Absolute path to themes directory

=cut

sub get_themes_dir {
    my $base = get_base_dir();
    return File::Spec->catdir($base, 'themes');
}

1;

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0

=cut
