package CLIO::Util::GitIgnore;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use File::Spec;
use Cwd qw(getcwd);
use CLIO::Core::Logger qw(should_log log_debug);

=head1 NAME

CLIO::Util::GitIgnore - Ensure .clio/ is properly gitignored

=head1 DESCRIPTION

Manages .gitignore entries for the .clio/ directory. Uses a whitelist
approach: ignore everything in .clio/ except instructions.md, which is
the project-level configuration file meant to be committed.

This replaces the old approach of manually adding each .clio/ subdirectory
to .gitignore every time a new feature was added.

Pattern:
    .clio/*
    !.clio/instructions.md

Called automatically on session startup and during /init, so new .clio/
internals (vault, sessions, logs, embeddings, etc.) are always ignored
without manual .gitignore maintenance.

=head1 SYNOPSIS

    use CLIO::Util::GitIgnore qw(ensure_clio_ignored);

    # Check and fix .gitignore (safe to call every startup)
    ensure_clio_ignored();

    # Or specify a work tree
    ensure_clio_ignored('/path/to/project');

=cut

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(ensure_clio_ignored);

# The canonical .gitignore entries for .clio/
# Ignore everything except instructions.md (project config for agents)
my @CLIO_ENTRIES = (
    '.clio/*',
    '!.clio/instructions.md',
);

# Old granular entries to clean up if found
my @OLD_ENTRIES = (
    '.clio/logs/',
    '.clio/sessions/',
    '.clio/memory/',
    '.clio/vault/',
    '.clio/snapshots/',
    '.clio/*json',
    '.clio/*.json',
    '.clio/embeddings/',
);

=head2 ensure_clio_ignored($work_tree)

Ensure .clio/ is properly gitignored in the project's .gitignore.

Only operates if the work tree is inside a git repository.
Idempotent - safe to call every startup.

Arguments:
- $work_tree: Path to check (default: current directory)

Returns: 1 if .gitignore was updated, 0 if already correct or not a git repo

=cut

sub ensure_clio_ignored {
    my ($work_tree) = @_;
    $work_tree ||= getcwd();

    # Only operate inside a git repository
    unless (_is_git_repo($work_tree)) {
        log_debug('GitIgnore', "Not a git repo, skipping .gitignore check");
        return 0;
    }

    my $gitignore_path = File::Spec->catfile($work_tree, '.gitignore');

    # Read existing .gitignore content
    my $content = '';
    if (-f $gitignore_path) {
        eval {
            open my $fh, '<:encoding(UTF-8)', $gitignore_path or die "Cannot read: $!";
            local $/;
            $content = <$fh>;
            close $fh;
        };
        if ($@) {
            log_debug('GitIgnore', "Failed to read .gitignore: $@");
            return 0;
        }
    }

    # Check if the canonical entries already exist
    my $has_clio_wildcard = ($content =~ /^\Q.clio\/*\E$/m || $content =~ /^\Q.clio\/\*\E$/m);
    my $has_instructions_exception = ($content =~ /^!\Q.clio\/instructions.md\E$/m);

    if ($has_clio_wildcard && $has_instructions_exception) {
        # Already correct - but still clean up old entries if present
        my $cleaned = _remove_old_entries($content);
        if ($cleaned ne $content) {
            _write_gitignore($gitignore_path, $cleaned);
            log_debug('GitIgnore', "Cleaned up old .clio/ entries from .gitignore");
            return 1;
        }
        log_debug('GitIgnore', ".gitignore already has correct .clio/ entries");
        return 0;
    }

    # Remove old granular entries first
    $content = _remove_old_entries($content);

    # Add canonical entries
    # Ensure file ends with newline before adding
    $content =~ s/\s*$/\n/ if length($content) > 0;

    $content .= "\n# CLIO (managed automatically)\n";
    for my $entry (@CLIO_ENTRIES) {
        $content .= "$entry\n";
    }

    _write_gitignore($gitignore_path, $content);
    log_debug('GitIgnore', "Updated .gitignore with .clio/ entries");
    return 1;
}

=head2 _remove_old_entries($content)

Remove old granular .clio/ entries from .gitignore content.
Also removes the comment line above them if it's a CLIO header.

=cut

sub _remove_old_entries {
    my ($content) = @_;

    for my $entry (@OLD_ENTRIES) {
        # Remove the entry line (with optional trailing whitespace)
        $content =~ s/^\Q$entry\E\s*\n//mg;
    }

    # Clean up any orphaned CLIO comment headers that now have nothing after them
    # Match "# CLIO" comment lines followed by a blank line or end of string
    $content =~ s/^#\s*CLIO[^\n]*\n(?=\s*\n|\s*$)//mg;

    # Collapse multiple consecutive blank lines into one
    $content =~ s/\n{3}/\n\n/g;

    return $content;
}

=head2 _write_gitignore($path, $content)

Write .gitignore content atomically.

=cut

sub _write_gitignore {
    my ($path, $content) = @_;

    my $tmp = "$path.tmp";
    eval {
        open my $fh, '>:encoding(UTF-8)', $tmp or die "Cannot write: $!";
        print $fh $content;
        close $fh;
        rename $tmp, $path or die "Cannot rename: $!";
    };
    if ($@) {
        unlink $tmp if -f $tmp;
        log_debug('GitIgnore', "Failed to write .gitignore: $@");
        return 0;
    }
    return 1;
}

=head2 _is_git_repo($path)

Check if path is inside a git repository.

=cut

sub _is_git_repo {
    my ($path) = @_;

    # Quick check for .git directory
    return 1 if -d File::Spec->catdir($path, '.git');

    # Fallback: ask git
    my $old_dir = getcwd();
    chdir $path or return 0;
    my $result = `git rev-parse --is-inside-work-tree 2>/dev/null`;
    chdir $old_dir;

    return (defined $result && $result =~ /true/) ? 1 : 0;
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut
