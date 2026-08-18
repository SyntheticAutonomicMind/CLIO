# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Util::PathResolver;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_info);
use FindBin;
use Carp qw(croak);
use File::Spec;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use Exporter 'import';

our @EXPORT_OK = qw(expand_tilde shell_quote strip_path_quotes find_ltm_path find_clio_dir);

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
    if ($opts{base_dir}) {
        # Create the directory if it doesn't exist
        if (!-d $opts{base_dir}) {
            require File::Path;
            File::Path::make_path($opts{base_dir});
        }
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
        # Development mode - use script directory for base (lib/ access)
        # CONFIG_DIR always goes to HOME for global config (API keys, provider)
        $BASE_DIR = $script_dir;
        $CONFIG_DIR = undef;  # Will fall through to Priority 4
        # Don't return - fall through to HOME resolution
    }
    
    # Priority 4: Installed mode - use ~/.clio
    my $home_dir = $ENV{HOME} || $ENV{USERPROFILE};
    if (!$home_dir) {
        croak "Cannot determine home directory (HOME/USERPROFILE not set)";
    }
    
    $CONFIG_DIR = File::Spec->catdir($home_dir, '.clio');
    
    # Create config directory if it doesn't exist with secure permissions
    if (!-d $CONFIG_DIR) {
        make_path($CONFIG_DIR, { mode => 0700 }) or croak "Cannot create config directory $CONFIG_DIR: $!";
        log_info('PathResolver', "[INFO] Created config directory: $CONFIG_DIR");
    }
    
    # In installed mode, BASE_DIR is still the script location (for lib/ access)
    # but CONFIG_DIR is ~/.clio (for data storage)
    $BASE_DIR = $script_dir;
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

**Important:** Sessions are PROJECT-SCOPED, not global.  
Uses current working directory's .clio/sessions/, not ~/.clio/sessions/

Returns: Absolute path to sessions directory (in current project)

=cut

sub get_sessions_dir {
    # Use current working directory for project-local sessions
    use Cwd qw(getcwd);
    my $project_dir = getcwd();
    
    my $sessions_dir = File::Spec->catdir($project_dir, '.clio', 'sessions');
    
    # Create if doesn't exist with secure permissions (0700 = owner only)
    if (!-d $sessions_dir) {
        make_path($sessions_dir, { mode => 0700 }) or croak "Cannot create sessions directory: $!";
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
    
    croak "Session ID required" unless $session_id;
    
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
        make_path($cache_dir, { mode => 0700 });
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

=head2 expand_tilde($path)

Expand a leading tilde in a path to the user's home directory.

Arguments:
- $path: Path that may start with ~/

Returns: Path with ~ replaced by $ENV{HOME}

=cut

sub expand_tilde {
    my ($path) = @_;
    return $path unless defined $path;
    $path =~ s{^~/}{$ENV{HOME}/} if $ENV{HOME};
    return $path;
}

=head2 get_themes_dir

Get the themes directory path.

Returns: Absolute path to themes directory

=cut

sub get_themes_dir {
    my $base = get_base_dir();
    return File::Spec->catdir($base, 'themes');
}

=head2 shell_quote($str)

Shell-quote a string for safe interpolation into shell commands.
Uses single-quote wrapping with embedded single-quote escaping.
This is a simplified version of String::ShellQuote for environments
where that module may not be available.

Arguments:
- $str: String to quote

Returns: Shell-quoted string

=cut

sub shell_quote {
    my ($str) = @_;
    return "''" unless defined $str && length $str;
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

=head2 strip_path_quotes($path)

Strip JSON-string-style quote characters from a path. LLMs sometimes
confuse JSON string syntax with string content and emit tool calls like
path=`"/home/foo/test.txt"` (with literal `"` chars) when they meant
`/home/foo/test.txt`. CLIO's directory-creation helpers (`make_path`,
`mkdir`) then treat the leading `"` as a directory name and create a
literal `"` directory - a small but persistent mess in the workspace.

This helper normalizes the common patterns:

  "/home/foo/test.txt"  -> /home/foo/test.txt     (balanced double quotes)
  '/home/foo/test.txt'  -> /home/foo/test.txt     (balanced single quotes)
  "test.txt"            -> test.txt               (balanced, short path)
  "/home/foo/test.txt   -> /home/foo/test.txt     (unbalanced leading ")
  'foo/bar              -> foo/bar                (unbalanced leading ')
  /home/foo/test.txt"   -> /home/foo/test.txt     (unbalanced trailing ")
  /home/foo/"test.txt"  -> /home/foo/"test.txt"   (embedded quotes preserved)
  foo"bar               -> foo"bar                (embedded quotes preserved)

Embedded quote characters are preserved (some filenames legitimately
contain them); only the leading and trailing characters that look like
JSON-string wrappers are stripped.

Arguments:
- $path: Path string from AI tool call

Returns: Sanitized path string (caller should treat empty result as missing)

=cut

sub strip_path_quotes {
    my ($path) = @_;
    return $path unless defined $path;

    # Balanced double or single quote wrapping: "..." or '...'
    # Match a leading quote, any non-greedy content with no embedded
    # matching quote, and the same quote at the end. Strip the wrapping
    # pair; leave embedded (mid-string) quotes alone. Reject empty
    # matches (e.g. "" or '') so they fall through to the empty-path
    # check downstream.
    if ($path =~ /^(["'])(.*?)\1$/s && length($2) > 0) {
        return $2;
    }

    # Unbalanced leading quote where the next character is path-like
    # ([/~.a-zA-Z0-9]). This catches the "AI emitted a leading `"` and
    # forgot the closing one" case. We only strip when the next char
    # looks like the start of a real path so we don't touch filenames
    # like `"foo"` whose first char IS the quote.
    if ($path =~ /^["']([\/~.a-zA-Z0-9])/s) {
        my $stripped = substr($path, 1);
        # If the result still ends with the same quote char, strip it too.
        # Catches "AI emitted matching quotes" where the leading-detection
        # branch matched first. Conservative: only strip if the remaining
        # string is plausibly path-like.
        $stripped = substr($stripped, 0, -1) if $stripped =~ /["']$/s && $stripped =~ /[\/~.a-zA-Z0-9]/s;
        return $stripped;
    }

    # Note: We intentionally do NOT strip a lone trailing quote. A
    # filename ending in `"` is unusual but legal, and stripping it
    # silently would change behavior the user did not ask for. The
    # common bug pattern (LLM wrapping a path in JSON-string quotes)
    # is caught by the balanced case above.

    return $path;
}

=head2 find_ltm_path($working_dir)

Resolve the canonical project-level LTM file path.

Walks up from $working_dir looking for .clio/ltm.json, stopping at the
project boundary (the directory containing a .git directory or filesystem
root). Returns the highest existing .clio/ltm.json within the project tree,
which prevents shadow LTM files from being created at intermediate paths
when sessions are started from subdirectories.

The walk is bounded by the project root (.git) and never crosses into
the user's home directory - so a session in /Users/me/projects/foo won't
accidentally resolve to /Users/me/.clio/ltm.json.

If no .clio/ltm.json exists anywhere in the project tree, returns
$working_dir + .clio/ltm.json (which will be created on first save).

Arguments:
  $working_dir - Directory to start the walk-up from (absolute preferred)

Returns:
  String path to the canonical .clio/ltm.json

=cut

sub find_ltm_path {
    my ($working_dir) = @_;

    $working_dir = abs_path($working_dir) || $working_dir;

    my $dir = $working_dir;
    my $canonical;
    my %visited;
    while ($dir && !defined $visited{$dir}) {
        $visited{$dir} = 1;
        my $candidate = File::Spec->catfile($dir, '.clio', 'ltm.json');
        if (-e $candidate) {
            $canonical = $candidate;
        }
        # Stop at project boundary - the dir containing .git - so we never
        # walk past the repo root into user-home/global config territory.
        last if -d File::Spec->catdir($dir, '.git');
        # File::Spec->catdir($dir, '..') does NOT simplify - just appends '/..'.
        # Use abs_path to canonicalize the parent so the loop converges on '/'.
        my $parent = abs_path(File::Spec->catdir($dir, '..'));
        last if !$parent || $parent eq $dir;
        $dir = $parent;
    }

    return $canonical || File::Spec->catfile($working_dir, '.clio', 'ltm.json');
}

=head2 find_clio_dir($working_dir)

Walk upward from $working_dir looking for a directory containing a
`.clio/` subdirectory. Returns the path to the directory containing
.clio/ (i.e. the project root), or $working_dir if none found.

Stops at the project boundary (directory containing `.git`) so the
search never walks past the repo root into user-home territory.

Used by PromptBuilder, PromptManager, and MemoryOperations to anchor
session-scoped files (goals, LTM, OpenSpec, memory) to the project root
instead of the current working directory. This prevents data loss when
CLIO is launched from a subdirectory or when the CWD changes between
turns.

Arguments:
- $working_dir: Directory to start searching from (default: current dir)

Returns:
- String path to the directory containing .clio/, or $working_dir as
  fallback if no .clio/ found within the project boundary.

=cut

sub find_clio_dir {
    my ($working_dir) = @_;

    $working_dir = abs_path($working_dir) || $working_dir || Cwd::getcwd();

    my $dir = $working_dir;
    my %visited;
    while ($dir && !defined $visited{$dir}) {
        $visited{$dir} = 1;
        return $dir if -d File::Spec->catdir($dir, '.clio');
        last if -d File::Spec->catdir($dir, '.git');
        my $parent = abs_path(File::Spec->catdir($dir, '..'));
        last if !$parent || $parent eq $dir;
        $dir = $parent;
    }

    return $working_dir;
}

1;

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0

=cut
