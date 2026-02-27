package CLIO::Session::Snapshot;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use File::Spec;
use File::Path qw(make_path);
use CLIO::Core::Logger qw(should_log log_debug);
use Cwd qw(getcwd);

=head1 CONSTANTS

=cut

# Maximum seconds for any single git operation (prevents hanging on huge work trees)
use constant GIT_TIMEOUT => 10;

# Maximum number of files we'll allow in a work tree for snapshots
# Above this threshold, git add -A becomes too slow
use constant MAX_SAFE_FILE_COUNT => 50000;

=head1 NAME

CLIO::Session::Snapshot - Git-based file change snapshots and revert

=head1 DESCRIPTION

Manages automatic snapshots of file changes made by the AI agent.
Uses a separate .git directory (stored in .clio/snapshots/) alongside
the project's real git repository, so snapshots never interfere with
the user's actual git history.

Snapshots are lightweight git tree objects (not commits), making them
fast to create and space-efficient.

=head1 SYNOPSIS

    my $snap = CLIO::Session::Snapshot->new(
        work_tree => '/path/to/project',
        debug => 1,
    );
    
    # Take a snapshot before AI makes changes
    my $hash = $snap->take();  # returns tree hash
    
    # After AI makes changes, get list of changed files
    my $patch = $snap->changed_files($hash);
    # Returns: { hash => '...', files => ['file1.pm', 'file2.pm'] }
    
    # Show diff since snapshot
    my $diff = $snap->diff($hash);
    
    # Revert all changes since snapshot
    $snap->revert($hash);
    
    # Revert specific files
    $snap->revert_files($hash, ['file1.pm']);

=cut

sub new {
    my ($class, %args) = @_;
    
    my $work_tree = $args{work_tree} || getcwd();
    
    # Safety check: refuse to operate on dangerous directories
    my $safe = _is_safe_work_tree($work_tree);
    
    # Store snapshot git directory inside .clio/snapshots/
    # This is project-local (not in ~/.clio) so it tracks the right files
    my $git_dir = File::Spec->catdir($work_tree, '.clio', 'snapshots');
    
    my $self = {
        work_tree => $work_tree,
        git_dir   => $git_dir,
        debug     => $args{debug} || 0,
        initialized => 0,
        safe      => $safe,
    };
    
    bless $self, $class;
    
    if (!$safe) {
        log_debug('Snapshot', "Snapshot disabled: work tree '$work_tree' is too broad (home dir, root, etc.)");
    }
    
    return $self;
}

=head2 _ensure_init

Initialize the snapshot git repository if not already done.
Creates a bare-like git repo in .clio/snapshots/ with the work tree
pointing to the project directory.

=cut

sub _ensure_init {
    my ($self) = @_;
    return 1 if $self->{initialized};
    
    my $git_dir = $self->{git_dir};
    my $work_tree = $self->{work_tree};
    
    # Create directory if needed
    unless (-d $git_dir) {
        make_path($git_dir);
        log_debug('Snapshot', "Creating snapshot git dir: $git_dir") if should_log('DEBUG');
        
        # Initialize git repo
        my $output = $self->_git('init');
        if (!defined $output) {
            warn "[WARN][Snapshot] Failed to initialize snapshot git repo\n";
            return 0;
        }
        
        # Configure to not convert line endings
        $self->_git('config', 'core.autocrlf', 'false');
        
        # Disable gpg signing for snapshot commits
        $self->_git('config', 'commit.gpgsign', 'false');
        
        log_debug('Snapshot', "Snapshot git repo initialized") if should_log('DEBUG');
    }
    
    # Ensure .clio/snapshots is excluded from its own tracking
    # Write an exclude file so the snapshot git ignores itself
    my $exclude_dir = File::Spec->catdir($git_dir, 'info');
    make_path($exclude_dir) unless -d $exclude_dir;
    my $exclude_file = File::Spec->catfile($exclude_dir, 'exclude');
    unless (-f $exclude_file && -s $exclude_file) {
        eval {
            open my $fh, '>:encoding(UTF-8)', $exclude_file or die "Cannot write exclude: $!";
            print $fh ".clio/\n";
            print $fh "ai-assisted/\n";
            print $fh ".DS_Store\n";
            close $fh;
        };
    }
    
    $self->{initialized} = 1;
    return 1;
}

=head2 _git(@args)

Execute a git command with the snapshot git-dir and work-tree.
Returns stdout on success, undef on failure.

=cut

sub _git {
    my ($self, @args) = @_;
    
    my $git_dir = $self->{git_dir};
    my $work_tree = $self->{work_tree};
    
    # Build command string - using shell execution to set cwd properly
    # We avoid Perl's chdir because it can resolve symlinks and cause
    # path mismatches with the git-dir/work-tree arguments
    my @cmd_parts = ("cd", _shell_quote($work_tree), "&&", 
                     "git", "--git-dir", _shell_quote($git_dir), 
                     "--work-tree", _shell_quote($work_tree));
    push @cmd_parts, map { _shell_quote($_) } @args;
    my $cmd = join(' ', @cmd_parts);
    
    log_debug('Snapshot', "Running: $cmd") if should_log('DEBUG');
    
    # Use timeout to prevent hanging on large work trees
    my $timeout = GIT_TIMEOUT;
    my $output;
    eval {
        local $SIG{ALRM} = sub { die "git_timeout\n" };
        alarm($timeout);
        $output = `$cmd 2>/dev/null`;
        alarm(0);
    };
    alarm(0);  # Ensure alarm is always cleared
    
    if ($@ && $@ =~ /git_timeout/) {
        log_debug('Snapshot', "Git command timed out after ${timeout}s: " . join(' ', @args));
        return undef;
    }
    
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        log_debug('Snapshot', "Git command failed (exit $exit_code): " . join(' ', @args)) if should_log('DEBUG');
        return undef;
    }
    
    chomp $output if defined $output;
    return $output;
}

# Shell-safe quoting for command arguments
sub _shell_quote {
    my ($str) = @_;
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

=head2 take

Take a snapshot of the current state of all tracked files.
Uses git add + write-tree for a lightweight snapshot (no commit object).

Returns: Tree hash string on success, undef on failure.

=cut

sub take {
    my ($self) = @_;
    
    # Safety: refuse to snapshot unsafe work trees
    return undef unless $self->{safe};
    
    return undef unless $self->_ensure_init();
    
    # Stage all current files
    $self->_git('add', '-A');
    
    # Write tree object (lightweight - no commit needed)
    my $hash = $self->_git('write-tree');
    
    if ($hash) {
        log_debug('Snapshot', "Snapshot taken: $hash") if should_log('DEBUG');
    } else {
        warn "[WARN][Snapshot] Failed to write snapshot tree\n";
    }
    
    return $hash;
}

=head2 changed_files($snapshot_hash)

Get list of files changed since a snapshot.

Arguments:
- $snapshot_hash: Tree hash from take()

Returns: Hashref with:
- hash: The snapshot hash
- files: Arrayref of changed file paths (relative to work tree)

=cut

sub changed_files {
    my ($self, $snapshot_hash) = @_;
    
    return { hash => $snapshot_hash, files => [] } unless $snapshot_hash;
    return { hash => $snapshot_hash, files => [] } unless $self->{safe};
    return { hash => $snapshot_hash, files => [] } unless $self->_ensure_init();
    
    # Stage current state to compare
    $self->_git('add', '-A');
    
    # Get changed file names
    my $output = $self->_git(
        '-c', 'core.quotepath=false',
        'diff', '--no-ext-diff', '--name-only', $snapshot_hash, '--', '.'
    );
    
    my @files;
    if (defined $output && length($output) > 0) {
        @files = grep { length($_) > 0 && $_ !~ /^\.clio\// } split(/\n/, $output);
    }
    
    return {
        hash  => $snapshot_hash,
        files => \@files,
    };
}

=head2 diff($snapshot_hash)

Get unified diff of all changes since a snapshot.

Arguments:
- $snapshot_hash: Tree hash from take()

Returns: Diff string (unified format), or empty string if no changes.

=cut

sub diff {
    my ($self, $snapshot_hash) = @_;
    
    return '' unless $snapshot_hash;
    return '' unless $self->{safe};
    return '' unless $self->_ensure_init();
    
    # Stage current state
    $self->_git('add', '-A');
    
    # Get full diff
    my $output = $self->_git(
        '-c', 'core.autocrlf=false',
        '-c', 'core.quotepath=false',
        'diff', '--no-ext-diff', $snapshot_hash, '--', '.'
    );
    
    return defined $output ? $output : '';
}

=head2 revert($snapshot_hash)

Revert ALL files to their state at the given snapshot.

Arguments:
- $snapshot_hash: Tree hash from take()

Returns: 1 on success, 0 on failure.

=cut

sub revert {
    my ($self, $snapshot_hash) = @_;
    
    return 0 unless $snapshot_hash;
    return 0 unless $self->{safe};
    return 0 unless $self->_ensure_init();
    
    log_debug('Snapshot', "Reverting all files to snapshot: $snapshot_hash") if should_log('DEBUG');
    
    # First, get list of files that changed (need to handle new files)
    my $changes = $self->changed_files($snapshot_hash);
    
    # Use read-tree + checkout-index to restore snapshot state
    my $read = $self->_git('read-tree', $snapshot_hash);
    if (!defined $read) {
        warn "[WARN][Snapshot] Failed to read-tree for revert\n";
        return 0;
    }
    
    my $checkout = $self->_git('checkout-index', '-a', '-f');
    if (!defined $checkout) {
        warn "[WARN][Snapshot] Failed to checkout-index for revert\n";
        return 0;
    }
    
    # Handle files that were added after the snapshot (need to be deleted)
    # These exist in current tree but not in the snapshot
    for my $file (@{$changes->{files}}) {
        my $full_path = File::Spec->catfile($self->{work_tree}, $file);
        # Check if file exists in snapshot
        my $in_snapshot = $self->_git('ls-tree', $snapshot_hash, '--', $file);
        if ((!defined $in_snapshot || $in_snapshot eq '') && -f $full_path) {
            log_debug('Snapshot', "Removing file not in snapshot: $file") if should_log('DEBUG');
            unlink $full_path;
        }
    }
    
    # Re-stage everything after revert so the index is clean for future snapshots
    # Remove stale lock file if present (can be left by read-tree)
    my $lock_file = File::Spec->catfile($self->{git_dir}, 'index.lock');
    unlink $lock_file if -f $lock_file;
    
    $self->_git('add', '-A');
    
    log_debug('Snapshot', "Revert complete") if should_log('DEBUG');
    return 1;
}

=head2 revert_files($snapshot_hash, \@files)

Revert specific files to their state at the given snapshot.

Arguments:
- $snapshot_hash: Tree hash from take()
- $files: Arrayref of file paths to revert (relative to work tree)

Returns: Number of files successfully reverted.

=cut

sub revert_files {
    my ($self, $snapshot_hash, $files) = @_;
    
    return 0 unless $snapshot_hash && $files && @$files;
    return 0 unless $self->{safe};
    return 0 unless $self->_ensure_init();
    
    my $count = 0;
    
    for my $file (@$files) {
        log_debug('Snapshot', "Reverting file: $file") if should_log('DEBUG');
        
        # Check if file existed in snapshot
        my $in_snapshot = $self->_git('ls-tree', $snapshot_hash, '--', $file);
        
        if (defined $in_snapshot && $in_snapshot ne '') {
            # File existed - restore it
            my $result = $self->_git('checkout', $snapshot_hash, '--', $file);
            if (defined $result) {
                $count++;
            } else {
                warn "[WARN][Snapshot] Failed to revert file: $file\n";
            }
        } else {
            # File didn't exist in snapshot - delete it
            my $full_path = File::Spec->catfile($self->{work_tree}, $file);
            if (-f $full_path) {
                if (unlink $full_path) {
                    $count++;
                    log_debug('Snapshot', "Deleted file not in snapshot: $file") if should_log('DEBUG');
                }
            }
        }
    }
    
    return $count;
}

=head2 cleanup($max_age_days)

Clean up old snapshot data to save space.

Arguments:
- $max_age_days: Prune objects older than this (default: 7)

=cut

sub cleanup {
    my ($self, $max_age_days) = @_;
    $max_age_days //= 7;
    
    return unless $self->_ensure_init();
    
    my $prune = "${max_age_days}.days";
    $self->_git('gc', "--prune=$prune");
    
    log_debug('Snapshot', "Cleanup complete (pruned > $max_age_days days)") if should_log('DEBUG');
}

=head2 is_available

Check if git is available and the snapshot system can function.

Returns: 1 if available, 0 if not.

=cut

sub is_available {
    my ($self) = @_;
    
    # Not available if work tree is unsafe
    return 0 unless $self->{safe};
    
    # Check if git is available
    my $version = `git --version 2>/dev/null`;
    return ($? == 0 && defined $version && $version =~ /git version/) ? 1 : 0;
}


=head2 _is_safe_work_tree($path)

Check if a directory is safe to use as a snapshot work tree.
Rejects home directories, filesystem root, and other overly broad paths
where running `git add -A` would index too many files and hang.

Arguments:
- $path: Absolute path to check

Returns: 1 if safe, 0 if dangerous

=cut

sub _is_safe_work_tree {
    my ($path) = @_;
    
    # Normalize the path (resolve . and ..)
    $path = File::Spec->rel2abs($path);
    # Remove trailing slash for consistent comparison
    $path =~ s{/+$}{} unless $path eq '/';
    
    # Reject filesystem root
    if ($path eq '/' || $path eq '') {
        return 0;
    }
    
    # Reject home directory (exact match)
    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '';
    $home =~ s{/+$}{} if $home;
    if ($home && $path eq $home) {
        return 0;
    }
    
    # Reject common system directories
    my @dangerous = qw(/tmp /var /etc /usr /opt /System /Library /Windows);
    for my $dir (@dangerous) {
        if ($path eq $dir) {
            return 0;
        }
    }
    
    # Reject paths with only one component after root (e.g., /Users, /home)
    # These are typically top-level system directories
    my @parts = File::Spec->splitdir($path);
    # Remove empty leading element from absolute paths
    shift @parts if @parts && $parts[0] eq '';
    if (@parts <= 1) {
        return 0;
    }
    
    return 1;
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut
