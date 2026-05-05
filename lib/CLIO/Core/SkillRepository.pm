# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::SkillRepository;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug log_info log_error log_warning);
use CLIO::Util::ConfigPath qw(get_config_dir);
use CLIO::Util::JSON qw(encode_json decode_json);
use File::Spec;
use File::Path qw(make_path);
use Carp qw(croak);

=head1 NAME

CLIO::Core::SkillRepository - Manage external skill repositories

=head1 DESCRIPTION

Manages configuration and lifecycle of external skill repositories.
Each repository is a Git repository containing SKILL.md files in one
of three common layouts:

=over 4

=item Type 1: Skills at repo root (e.g., ComposioHQ/awesome-claude-skills)

  repo/
  ├── skill-a/SKILL.md
  ├── skill-b/SKILL.md
  └── README.md

=item Type 2: Skills in subdirectory (e.g., .github/skills/)

  repo/
  ├── .github/skills/skill-a/SKILL.md
  └── README.md

=item Type 3: Single skill per repo

  repo/
  ├── SKILL.md
  └── scripts/

=back

Repository configuration is persisted to C<~/.clio/skill-repositories.json>.
Cloned repositories are cached in C<~/.clio/skill-cache/>.

=head1 SYNOPSIS

    my $repo_mgr = CLIO::Core::SkillRepository->new(debug => 1);
    
    # Add a repository
    $repo_mgr->add_repo('awesome-claude-skills',
        'https://github.com/ComposioHQ/awesome-claude-skills');
    
    # Sync all repositories
    $repo_mgr->sync_all();
    
    # List configured repositories
    my $repos = $repo_mgr->list_repos();
    
    # Remove a repository
    $repo_mgr->remove_repo('awesome-claude-skills');

=cut

# Default paths
our $REPOS_CONFIG_FILE;
our $CACHE_DIR;

BEGIN {
    $REPOS_CONFIG_FILE = sub {
        File::Spec->catfile(get_config_dir(), 'skill-repositories.json')
    };
    $CACHE_DIR = sub {
        File::Spec->catdir(get_config_dir(), 'skill-cache')
    };
}

=head2 new

Create a new SkillRepository manager.

Arguments:
- debug: Enable debug output (optional)

Returns: SkillRepository instance

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        debug => $opts{debug} || 0,
        repos_config_file => $opts{repos_config_file} || $REPOS_CONFIG_FILE->(),
        cache_dir => $opts{cache_dir} || $CACHE_DIR->(),
        repos => {},
    };
    
    bless $self, $class;
    $self->_load_config();
    return $self;
}

=head2 add_repo

Add a new skill repository.

Arguments:
- $name: Short name for the repository (alphanumeric, hyphens, underscores)
- $url: Git repository URL (HTTPS or SSH)
- %opts: Optional parameters
  - branch: Git branch to checkout (default: main)
  - enabled: Whether repo is active (default: 1)
  - subpath: Subdirectory within repo containing skills (default: auto-detect)

Returns: { success => 1, repo => \%repo } or { success => 0, error => $msg }

=cut

sub add_repo {
    my ($self, $name, $url, %opts) = @_;
    
    unless ($name && $name =~ /^[a-zA-Z0-9_-]+$/) {
        return { success => 0, error => "Invalid repository name (alphanumeric, hyphens, underscores only)" };
    }
    
    unless ($url) {
        return { success => 0, error => "Repository URL is required" };
    }
    
    if ($self->{repos}{$name}) {
        return { success => 0, error => "Repository '$name' already exists. Remove it first." };
    }
    
    my $repo = {
        name => $name,
        url => $url,
        branch => $opts{branch} || 'main',
        enabled => defined($opts{enabled}) ? $opts{enabled} : 1,
        subpath => $opts{subpath} || '',
        added => time(),
        last_sync => 0,
        skill_count => 0,
    };
    
    $self->{repos}{$name} = $repo;
    $self->_save_config();
    
    log_info('SkillRepository', "Added repository '$name' ($url)");
    
    return { success => 1, repo => $repo };
}

=head2 remove_repo

Remove a skill repository and its cached files.

Arguments:
- $name: Repository name
- $keep_cache: If true, don't delete cached files (optional)

Returns: { success => 1 } or { success => 0, error => $msg }

=cut

sub remove_repo {
    my ($self, $name, $keep_cache) = @_;
    
    unless ($self->{repos}{$name}) {
        return { success => 0, error => "Repository '$name' not found" };
    }
    
    # Remove cached files
    unless ($keep_cache) {
        my $cache_path = File::Spec->catdir($self->{cache_dir}, $name);
        if (-d $cache_path) {
            require File::Path;
            File::Path::remove_tree($cache_path);
            log_debug('SkillRepository', "Removed cache for '$name'");
        }
    }
    
    delete $self->{repos}{$name};
    $self->_save_config();
    
    log_info('SkillRepository', "Removed repository '$name'");
    
    return { success => 1 };
}

=head2 get_repo

Get repository configuration by name.

Arguments:
- $name: Repository name

Returns: Repository hashref or undef

=cut

sub get_repo {
    my ($self, $name) = @_;
    return $self->{repos}{$name};
}

=head2 list_repos

List all configured repositories.

Returns: Arrayref of repository hashrefs

=cut

sub list_repos {
    my ($self) = @_;
    
    return [ sort { $a->{name} cmp $b->{name} } values %{$self->{repos}} ];
}

=head2 enable_repo

Enable a disabled repository.

Arguments:
- $name: Repository name

Returns: { success => 1 } or { success => 0, error => $msg }

=cut

sub enable_repo {
    my ($self, $name) = @_;
    
    unless ($self->{repos}{$name}) {
        return { success => 0, error => "Repository '$name' not found" };
    }
    
    $self->{repos}{$name}{enabled} = 1;
    $self->_save_config();
    
    return { success => 1 };
}

=head2 disable_repo

Disable a repository without removing it.

Arguments:
- $name: Repository name

Returns: { success => 1 } or { success => 0, error => $msg }

=cut

sub disable_repo {
    my ($self, $name) = @_;
    
    unless ($self->{repos}{$name}) {
        return { success => 0, error => "Repository '$name' not found" };
    }
    
    $self->{repos}{$name}{enabled} = 0;
    $self->_save_config();
    
    return { success => 1 };
}

=head2 sync_repo

Sync a single repository (clone or pull).

Arguments:
- $name: Repository name

Returns: { success => 1, updated => $bool, skill_count => $count }
         or { success => 0, error => $msg }

=cut

sub sync_repo {
    my ($self, $name) = @_;
    
    my $repo = $self->{repos}{$name};
    unless ($repo) {
        return { success => 0, error => "Repository '$name' not found" };
    }
    
    unless ($repo->{enabled}) {
        return { success => 0, error => "Repository '$name' is disabled. Enable it first." };
    }
    
    my $cache_path = File::Spec->catdir($self->{cache_dir}, $name);
    my $updated = 0;
    
    if (-d $cache_path && -d File::Spec->catdir($cache_path, '.git')) {
        # Pull existing repository
        my $output = `cd "$cache_path" && git pull --ff-only 2>&1`;
        my $exit_code = $? >> 8;
        
        if ($exit_code != 0) {
            # Pull failed - try reset and pull
            log_warning('SkillRepository', "Pull failed for '$name', attempting reset: $output");
            $output = `cd "$cache_path" && git fetch origin && git reset --hard "origin/$repo->{branch}" 2>&1`;
            $exit_code = $? >> 8;
            
            if ($exit_code != 0) {
                return { success => 0, error => "Failed to sync '$name': $output" };
            }
        }
        
        # Check if there were updates
        $updated = ($output !~ /Already up to date/i) ? 1 : 0;
        log_debug('SkillRepository', "Pulled '$name': $output");
    }
    else {
        # Clone new repository
        make_path($cache_path) unless -d $cache_path;
        
        my $branch = $repo->{branch} || 'main';
        my $output = `git clone --branch "$branch" --depth 1 "$repo->{url}" "$cache_path" 2>&1`;
        my $exit_code = $? >> 8;
        
        if ($exit_code != 0) {
            # Try without branch specification (default branch may differ)
            $output = `git clone --depth 1 "$repo->{url}" "$cache_path" 2>&1`;
            $exit_code = $? >> 8;
            
            if ($exit_code != 0) {
                # Clean up failed clone
                require File::Path;
                File::Path::remove_tree($cache_path) if -d $cache_path;
                return { success => 0, error => "Failed to clone '$name': $output" };
            }
        }
        
        $updated = 1;
        log_debug('SkillRepository', "Cloned '$name' to $cache_path");
    }
    
    # Update sync timestamp
    $repo->{last_sync} = time();
    
    # Count skills in the repository
    my $skill_count = $self->_count_skills_in_cache($name);
    $repo->{skill_count} = $skill_count;
    
    $self->_save_config();
    
    log_info('SkillRepository', "Synced '$name': $skill_count skills found" .
        ($updated ? " (updated)" : " (no changes)"));
    
    return {
        success => 1,
        updated => $updated,
        skill_count => $skill_count,
    };
}

=head2 sync_all

Sync all enabled repositories.

Returns: Arrayref of results, one per repository

=cut

sub sync_all {
    my ($self) = @_;
    
    my @results;
    for my $repo ($self->list_repos()->@*) {
        next unless $repo->{enabled};
        push @results, {
            name => $repo->{name},
            result => $self->sync_repo($repo->{name}),
        };
    }
    
    return \@results;
}

=head2 get_cache_path

Get the local cache path for a repository.

Arguments:
- $name: Repository name

Returns: Path string or undef if repo not found

=cut

sub get_cache_path {
    my ($self, $name) = @_;
    
    return undef unless $self->{repos}{$name};
    return File::Spec->catdir($self->{cache_dir}, $name);
}

=head2 get_repo_skill_count

Get the number of skills discovered in a repository.

Arguments:
- $name: Repository name

Returns: Integer count

=cut

sub get_repo_skill_count {
    my ($self, $name) = @_;
    
    my $repo = $self->{repos}{$name};
    return 0 unless $repo;
    
    return $repo->{skill_count} || 0;
}

=head2 _load_config

Load repository configuration from JSON file.

=cut

sub _load_config {
    my ($self) = @_;
    
    return unless -f $self->{repos_config_file};
    
    open my $fh, '<:encoding(UTF-8)', $self->{repos_config_file} or return;
    my $json = do { local $/; <$fh> };
    close $fh;
    
    my $data = eval { decode_json($json) };
    if ($@) {
        log_error('SkillRepository', "Failed to parse config: $@");
        return;
    }
    
    $self->{repos} = $data->{repositories} || {};
    
    log_debug('SkillRepository', "Loaded " . scalar(keys %{$self->{repos}}) . " repositories");
}

=head2 _save_config

Save repository configuration to JSON file.

=cut

sub _save_config {
    my ($self) = @_;
    
    my $data = {
        version => '1.0',
        repositories => $self->{repos},
        metadata => {
            last_updated => time(),
            total_repos => scalar(keys %{$self->{repos}}),
        },
    };
    
    # Ensure directory exists
    my ($volume, $dir, $file) = File::Spec->splitpath($self->{repos_config_file});
    my $full_dir = File::Spec->catpath($volume, $dir, '');
    make_path($full_dir) unless -d $full_dir;
    
    # Atomic write
    my $temp = $self->{repos_config_file} . '.tmp';
    open my $fh, '>:encoding(UTF-8)', $temp or do {
        log_error('SkillRepository', "Cannot write config: $!");
        return;
    };
    print $fh encode_json($data);
    close $fh;
    
    rename($temp, $self->{repos_config_file}) or do {
        log_error('SkillRepository', "Cannot rename config: $!");
        unlink $temp;
        return;
    };
    
    log_debug('SkillRepository', "Saved " . scalar(keys %{$self->{repos}}) . " repositories");
}

=head2 _count_skills_in_cache

Count SKILL.md files in a cached repository.

Arguments:
- $name: Repository name

Returns: Integer count of skills found

=cut

sub _count_skills_in_cache {
    my ($self, $name) = @_;
    
    my $cache_path = $self->get_cache_path($name);
    return 0 unless $cache_path && -d $cache_path;
    
    my $repo = $self->{repos}{$name};
    my $search_path = $cache_path;
    
    # If subpath is configured, search within it
    if ($repo->{subpath}) {
        $search_path = File::Spec->catdir($cache_path, $repo->{subpath});
        return 0 unless -d $search_path;
    }
    
    # Find all SKILL.md files
    my $count = 0;
    $self->_find_skill_files($search_path, sub {
        $count++;
    });
    
    return $count;
}

=head2 _find_skill_files

Recursively find SKILL.md files and invoke callback for each.

Arguments:
- $dir: Directory to search
- $callback: Coderef called with ($skill_md_path) for each found file

=cut

sub _find_skill_files {
    my ($self, $dir, $callback) = @_;
    
    return unless -d $dir;
    
    opendir my $dh, $dir or return;
    my @entries = readdir($dh);
    closedir $dh;
    
    for my $entry (@entries) {
        next if $entry eq '.' || $entry eq '..';
        next if $entry eq '.git';
        
        my $path = File::Spec->catdir($dir, $entry);
        
        if (-d $path) {
            # Check if this directory contains SKILL.md
            my $skill_md = File::Spec->catfile($path, 'SKILL.md');
            if (-f $skill_md) {
                $callback->($skill_md);
            }
            
            # Recurse into subdirectories (but not into skill directories themselves)
            # Only recurse if no SKILL.md was found at this level
            else {
                $self->_find_skill_files($path, $callback);
            }
        }
        elsif ($entry eq 'SKILL.md' && -f $path) {
            # SKILL.md at the root of the search path (single-skill repo)
            $callback->($path);
        }
    }
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

Copyright (c) 2026 CLIO Project

=cut