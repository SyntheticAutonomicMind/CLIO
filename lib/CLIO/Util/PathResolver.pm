# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Util::PathResolver;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug);
use FindBin;
use Carp qw(croak);
use File::Spec;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use Exporter 'import';

our @EXPORT_OK = qw(expand_tilde shell_quote strip_path_quotes find_ltm_path
    find_clio_dir get_project_data_dir get_project_data_dir_for
    get_project_sessions_dir get_project_session_file get_project_ltm_file
    get_project_memory_dir get_project_vault_dir get_project_logs_dir);

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

# Cached project data directory (resolved once via UUID from .clio/project_uuid)
our $PROJECT_DATA_DIR;
our $PROJECT_UUID;
# The project root + working directory the cache above was resolved for.
# When the working directory moves into a different project (in-process
# project switches: sub-agents, parallel execution, tests), the cache is
# invalidated and re-resolved so each project keeps its own data dir.
our $PROJECT_RESOLVED_ROOT;
our $PROJECT_RESOLVED_CWD;

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
        log_debug('PathResolver', "[INFO] Created config directory: $CONFIG_DIR");
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

Sessions are stored under the project data directory (~/.clio/projects/<uuid>/sessions/)
so they don't pollute the project tree. The project UUID is resolved from
.clio/project_uuid in the project root (generated on first launch).

Returns: Absolute path to sessions directory

=cut

sub get_sessions_dir {
    my $sessions_dir = get_project_sessions_dir();
    return $sessions_dir;
}

=head2 get_project_data_dir

Get the project data directory. All CLIO runtime data (sessions, LTM,
memory, vault, logs) lives here, keyed by a project UUID stored in
C<.clio/project_uuid>. This keeps runtime data out of the project tree
so it doesn't pollute grep/ripgrep searches.

On first launch, a UUID v4 is generated and written to
C<.clio/project_uuid> in the project root. Subsequent launches read
the same UUID, so data persists even if the project directory moves
(the C<project_uuid> file moves with the project).

A one-time migration runs on first launch: if old runtime data is found
in the project's C<.clio/> directory (sessions/, ltm.json, memory/, vault/,
logs/), it is moved to the new project data directory.

Returns: Absolute path to project data directory (e.g. ~/.clio/projects/<uuid>/)

=cut

sub get_project_data_dir {
    my $cwd = Cwd::getcwd();

    # Fast path: working directory unchanged since the last resolution.
    if (defined $PROJECT_DATA_DIR && defined $PROJECT_RESOLVED_CWD
        && defined $cwd && $cwd eq $PROJECT_RESOLVED_CWD) {
        return $PROJECT_DATA_DIR;
    }

    my $project_root = find_clio_dir();

    # Working directory moved but the project root is the same (e.g. cd
    # into a subdirectory of the same project): keep the cached UUID.
    if (defined $PROJECT_DATA_DIR && defined $PROJECT_RESOLVED_ROOT
        && defined $project_root && $PROJECT_RESOLVED_ROOT eq $project_root) {
        $PROJECT_RESOLVED_CWD = $cwd;
        return $PROJECT_DATA_DIR;
    }

    # First resolution, or the project root changed (in-process project
    # switch). Drop the stale cache and re-resolve for this project so
    # each project keeps its own UUID-keyed data directory.
    $PROJECT_DATA_DIR = undef;
    $PROJECT_UUID = undef;
    $PROJECT_RESOLVED_ROOT = $project_root;
    $PROJECT_RESOLVED_CWD = $cwd;

    init() unless defined $CONFIG_DIR;

    my $clio_dir = File::Spec->catdir($project_root, '.clio');

    # Ensure .clio/ exists at the project root (create on first launch)
    unless (-d $clio_dir) {
        make_path($clio_dir, { mode => 0700 });
    }

    # Read or generate project UUID
    my $uuid_file = File::Spec->catfile($clio_dir, 'project_uuid');
    my $uuid;

    if (-f $uuid_file) {
        eval {
            open my $fh, '<', $uuid_file or die "Cannot read: $!";
            $uuid = <$fh>;
            close $fh;
            chomp $uuid;
        };
        # Validate UUID format
        if ($uuid && $uuid !~ /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/) {
            log_debug('PathResolver', "Stale/invalid project_uuid, will regenerate");
            $uuid = undef;
        }
    }

    my $config_base = _get_config_base_dir();
    $PROJECT_DATA_DIR = File::Spec->catdir($config_base, 'projects');

    unless (defined $uuid && length $uuid) {
        # Generate new UUID v4
        require CLIO::Util::UUID;
        $uuid = CLIO::Util::UUID::uuid_v4();

        # Write UUID file
        eval {
            open my $fh, '>:utf8', $uuid_file or die "Cannot write: $!";
            print $fh $uuid;
            close $fh;
            chmod 0600, $uuid_file;
        };
        if ($@) {
            log_debug('PathResolver', "Failed to write project_uuid: $@");
        }

        log_debug('PathResolver', "Generated new project UUID: $uuid for $clio_dir");

        # One-time migration: move old runtime data from .clio/ to project data dir
        $PROJECT_UUID = $uuid;
        $PROJECT_DATA_DIR = File::Spec->catdir($config_base, 'projects', $uuid);
        make_path($PROJECT_DATA_DIR, { mode => 0700 }) unless -d $PROJECT_DATA_DIR;
        _migrate_old_project_data($clio_dir, $PROJECT_DATA_DIR);
        return $PROJECT_DATA_DIR;
    }

    $PROJECT_UUID = $uuid;
    $PROJECT_DATA_DIR = File::Spec->catdir($config_base, 'projects', $uuid);
    make_path($PROJECT_DATA_DIR, { mode => 0700 }) unless -d $PROJECT_DATA_DIR;

    return $PROJECT_DATA_DIR;
}

=head2 get_project_data_dir_for($project_root)

Resolve the project data directory for an arbitrary project root
(not just the current working directory). Used by cross-project
discovery tools (e.g. Puppeteer) that scan sibling projects.

Arguments:
- $project_root: Absolute path to the project's .clio/ parent directory

Returns: Project data directory path, or undef if the project has no UUID

=cut

sub get_project_data_dir_for {
    my ($project_root) = @_;

    return undef unless $project_root && -d $project_root;

    init() unless defined $CONFIG_DIR;

    my $uuid_file = File::Spec->catfile($project_root, '.clio', 'project_uuid');
    return undef unless -f $uuid_file;

    my $uuid;
    eval {
        open my $fh, '<', $uuid_file or die "Cannot read: $!";
        $uuid = <$fh>;
        close $fh;
        chomp $uuid;
    };
    return undef unless $uuid && $uuid =~ /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

    my $config_base = _get_config_base_dir();
    return File::Spec->catdir($config_base, 'projects', $uuid);
}

=head2 _get_config_base_dir (Internal)

Resolve the base directory for ~/.clio (respects --config override and
CLIO_CONFIG_DIR env var for test isolation).

=cut

sub _get_config_base_dir {
    # Priority 1: --config override (sets CONFIG_DIR via init)
    if (defined $CONFIG_DIR) {
        return $CONFIG_DIR;
    }
    # Priority 2: CLIO_CONFIG_DIR env var (set by test harness)
    if (defined $ENV{CLIO_CONFIG_DIR} && -d $ENV{CLIO_CONFIG_DIR}) {
        return $ENV{CLIO_CONFIG_DIR};
    }
    # Priority 3: Default ~/.clio
    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '.';
    return File::Spec->catdir($home, '.clio');
}

=head2 _migrate_old_project_data (Internal)

One-time migration: move runtime data from the old project-local .clio/
layout (<project>/.clio/sessions/, <project>/.clio/ltm.json, etc.) to
the new centralized project data directory (~/.clio/projects/<uuid>/).

This only runs once per project, when a new UUID is first generated.
After migration, only user-authored files remain in .clio/ (instructions.md,
skills/, skills.json, devices.json, project_uuid).

=cut

sub _migrate_old_project_data {
    my ($clio_dir, $data_dir) = @_;

    my $changed = 0;

    # Helper: move a directory tree
    my $move_dir = sub {
        my ($src, $dst) = @_;
        return 0 unless -d $src;
        return 0 if -d $dst && _dir_has_content($dst);
        my $result = make_path($dst, { mode => 0700 });
        unless ($result) {
            log_debug('PathResolver', "Migration: failed to create $dst: $!");
            return 0;
        }
        eval {
            my $copied = _copy_tree($src, $dst);
            # Even if the dir was empty (0 files copied), we still want
            # to remove the source to avoid leaving stale empty dirs
            # in the project tree.
            require File::Path;
            File::Path::remove_tree($src);
            if ($copied) {
                log_debug('PathResolver', "Migration: moved $src -> $dst ($copied files)");
                return 1;
            } else {
                log_debug('PathResolver', "Migration: moved empty $src -> $dst");
                return 1;
            }
        };
        if ($@) {
            log_debug('PathResolver', "Migration: error moving $src: $@");
            return 0;
        }
        return 0;
    };

    my $move_file = sub {
        my ($src, $dst) = @_;
        return 0 unless -f $src;
        return 0 if -f $dst;
        require File::Copy;
        if (File::Copy::copy($src, $dst)) {
            chmod 0600, $dst;
            unlink $src;
            log_debug('PathResolver', "Migration: moved $src -> $dst");
            return 1;
        } else {
            log_debug('PathResolver', "Migration: copy failed for $src: $!");
            return 0;
        }
    };

    # Migrate sessions/
    my $old_sessions = File::Spec->catdir($clio_dir, 'sessions');
    my $new_sessions = File::Spec->catdir($data_dir, 'sessions');
    if (-d $old_sessions) {
        if ($move_dir->($old_sessions, $new_sessions)) { $changed++; }
    }

    # Migrate ltm.json
    my $old_ltm = File::Spec->catfile($clio_dir, 'ltm.json');
    my $new_ltm = File::Spec->catfile($data_dir, 'ltm.json');
    if (-f $old_ltm) {
        if ($move_file->($old_ltm, $new_ltm)) { $changed++; }
    }

    # Migrate memory/
    my $old_memory = File::Spec->catdir($clio_dir, 'memory');
    my $new_memory = File::Spec->catdir($data_dir, 'memory');
    if (-d $old_memory) {
        if ($move_dir->($old_memory, $new_memory)) { $changed++; }
    }

    # Migrate vault/
    my $old_vault = File::Spec->catdir($clio_dir, 'vault');
    my $new_vault = File::Spec->catdir($data_dir, 'vault');
    if (-d $old_vault) {
        if ($move_dir->($old_vault, $new_vault)) { $changed++; }
    }

    # Migrate logs/
    my $old_logs = File::Spec->catdir($clio_dir, 'logs');
    my $new_logs = File::Spec->catdir($data_dir, 'logs');
    if (-d $old_logs) {
        if ($move_dir->($old_logs, $new_logs)) { $changed++; }
    }

    if ($changed) {
        log_debug('PathResolver', "Migration complete: moved $changed data component(s) to $data_dir");
    }
}

=head2 _dir_has_content (Internal)

Check if a directory has any non-hidden content.

=cut

sub _dir_has_content {
    my ($dir) = @_;
    return 0 unless -d $dir;
    if (opendir(my $dh, $dir)) {
        while (my $entry = readdir($dh)) {
            next if $entry eq '.' || $entry eq '..';
            return 1;
        }
        closedir($dh);
    }
    return 0;
}

=head2 _copy_tree (Internal)

Copy a directory tree recursively. Minimal implementation using
core Perl only (no File::Copy::Recursive dependency).

Arguments:
- $src: Source directory
- $dst: Destination directory

Returns: Number of files copied, 0 on failure

=cut

sub _copy_tree {
    my ($src, $dst) = @_;

    unless (-d $src) {
        return 0;
    }

    unless (-d $dst) {
        make_path($dst, { mode => 0700 }) or return 0;
    }

    my $count = 0;
    if (opendir(my $dh, $src)) {
        while (my $entry = readdir($dh)) {
            next if $entry eq '.' || $entry eq '..';
            my $src_path = File::Spec->catfile($src, $entry);
            my $dst_path = File::Spec->catfile($dst, $entry);
            if (-d $src_path) {
                $count += _copy_tree($src_path, $dst_path);
            } elsif (-f $src_path) {
                require File::Copy;
                if (File::Copy::copy($src_path, $dst_path)) {
                    chmod((stat($src_path))[2] & 0777, $dst_path);
                    $count++;
                }
            }
        }
        closedir $dh;
    }

    return $count;
}

=head2 get_project_sessions_dir

Get the project sessions directory. Sessions are stored under
~/.clio/projects/<uuid>/sessions/ to keep them out of the project tree.

Returns: Absolute path to project sessions directory

=cut

sub get_project_sessions_dir {
    my $data_dir = get_project_data_dir();
    my $sessions_dir = File::Spec->catdir($data_dir, 'sessions');
    make_path($sessions_dir, { mode => 0700 }) unless -d $sessions_dir;
    return $sessions_dir;
}

=head2 get_project_session_file

Get the full path to a session file in the project data directory.

Arguments:
- $session_id: Session identifier

Returns: Absolute path to session file

=cut

sub get_project_session_file {
    my ($session_id) = @_;

    croak "Session ID required" unless $session_id;

    my $sessions_dir = get_project_sessions_dir();
    return File::Spec->catfile($sessions_dir, "$session_id.json");
}

=head2 get_project_ltm_file

Get the project-level long-term memory file path.

Returns: Absolute path to project LTM file

=cut

sub get_project_ltm_file {
    my $data_dir = get_project_data_dir();
    return File::Spec->catfile($data_dir, 'ltm.json');
}

=head2 get_project_memory_dir

Get the project session-memory directory for key-value storage.

Returns: Absolute path to project memory directory

=cut

sub get_project_memory_dir {
    my $data_dir = get_project_data_dir();
    my $memory_dir = File::Spec->catdir($data_dir, 'memory');
    make_path($memory_dir, { mode => 0700 }) unless -d $memory_dir;
    return $memory_dir;
}

=head2 get_project_vault_dir

Get the project FileVault directory for file backup/undo.

Returns: Absolute path to project vault directory

=cut

sub get_project_vault_dir {
    my $data_dir = get_project_data_dir();
    my $vault_dir = File::Spec->catdir($data_dir, 'vault');
    make_path($vault_dir, { mode => 0700 }) unless -d $vault_dir;
    return $vault_dir;
}

=head2 get_project_logs_dir

Get the project logs directory for tool logs and process stats.

Returns: Absolute path to project logs directory

=cut

sub get_project_logs_dir {
    my $data_dir = get_project_data_dir();
    my $logs_dir = File::Spec->catdir($data_dir, 'logs');
    make_path($logs_dir, { mode => 0700 }) unless -d $logs_dir;
    return $logs_dir;
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

    # We intentionally do NOT strip a lone trailing quote. A
    # filename ending in `"` is unusual but legal; stripping it
    # would change behavior the user did not ask for. The common
    # bug pattern (LLM wrapping a path in JSON-string quotes) is
    # caught by the balanced case above.

    return $path;
}

=head2 find_ltm_path($working_dir)

Resolve the canonical project-level LTM file path.

Delegates to L</get_project_ltm_file>, which resolves the project UUID
from C<.clio/project_uuid> and returns the path under
C<~/.clio/projects/<uuid>/ltm.json>. The project data directory is
shared across all sessions in the same project and does not pollute
the project tree.

The $working_dir argument is accepted for backward compatibility but
is no longer used for path resolution - the project is determined by
the working directory at first launch (cached for the process lifetime).

Arguments:
  $working_dir - (ignored, kept for backward compatibility)

Returns:
  String path to the project LTM file

=cut

sub find_ltm_path {
    return get_project_ltm_file();
}

=head2 find_clio_dir($working_dir)

Walk upward from $working_dir looking for a directory containing a
C<.clio/> subdirectory. Returns the path to the directory containing
.clio/ (i.e. the project root), or the directory containing C<.git/>
(the repository root) if no .clio/ is found within the project boundary.

If neither .clio/ nor .git/ is found, returns $working_dir.

Stops at the project boundary (directory containing C<.git/>) so the
search never walks past the repo root into user-home territory.

Used by PromptBuilder, PromptManager, and MemoryOperations to anchor
session-scoped files (goals, LTM, OpenSpec, memory) to the project root
instead of the current working directory.

Arguments:
- $working_dir: Directory to start searching from (default: current dir)

Returns:
- String path to the project root directory

=cut

sub find_clio_dir {
    my ($working_dir) = @_;

    $working_dir = defined $working_dir ? abs_path($working_dir) : undef;
    $working_dir ||= Cwd::getcwd();

    my $dir = $working_dir;
    my %visited;
    while ($dir && !defined $visited{$dir}) {
        $visited{$dir} = 1;
        return $dir if -d File::Spec->catdir($dir, '.clio');
        # Return the git root when .clio/ is not found - this is the
        # project boundary and the correct place to create .clio/ on
        # first launch.
        return $dir if -d File::Spec->catdir($dir, '.git');
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
