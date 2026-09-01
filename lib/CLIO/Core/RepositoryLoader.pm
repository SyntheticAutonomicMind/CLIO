# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::RepositoryLoader;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug log_warning);
use CLIO::Util::ConfigPath qw(get_config_dir);
use File::Spec;
use File::Path qw(make_path);
use Carp qw(croak);

=head1 NAME

CLIO::Core::RepositoryLoader - Load skills from cached repositories

=head1 DESCRIPTION

Scans locally cached skill repositories for SKILL.md files, parses
their YAML frontmatter, and makes the skills available to the
SkillManager. Works with CLIO::Core::SkillRepository which handles
the repository configuration and cloning.

Supports three repository layouts:

=over 4

=item Root-level skills: C<repo/skill-name/SKILL.md>

=item Subdirectory skills: C<repo/.github/skills/skill-name/SKILL.md>

=item Single-skill repo: C<repo/SKILL.md>

=back

=head1 SYNOPSIS

    my $loader = CLIO::Core::RepositoryLoader->new(debug => 1);
    
    # Load all skills from all cached repositories
    my $skills = $loader->load_all_skills();
    
    # Load skills from a specific repository
    my $skills = $loader->load_repo_skills('awesome-claude-skills');
    
    # Get a single skill's content
    my $content = $loader->read_skill_content($skill_md_path);

=cut

=head2 new

Create a new RepositoryLoader.

Arguments:
- debug: Enable debug output (optional)
- cache_dir: Override default cache directory (optional)

Returns: RepositoryLoader instance

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        debug => $opts{debug} || 0,
        cache_dir => $opts{cache_dir} || 
            File::Spec->catdir(get_config_dir(), 'skill-cache'),
        _skill_cache => {},
    };
    
    bless $self, $class;
    return $self;
}

=head2 load_all_skills

Load skills from all cached repositories.

Arguments:
- $repo_mgr: CLIO::Core::SkillRepository instance (optional, for metadata)

Returns: Hashref of skills keyed by name, each containing:
  name, description, prompt, type, source_repo, skill_path, readonly

=cut

sub load_all_skills {
    my ($self, $repo_mgr) = @_;
    
    my %all_skills;
    
    # If we have a repo manager, use it to enumerate repos
    if ($repo_mgr) {
        for my $repo ($repo_mgr->list_repos()->@*) {
            next unless $repo->{enabled};
            next unless $repo->{last_sync};  # Skip unsynced repos
            
            my $repo_skills = $self->load_repo_skills($repo->{name});
            %all_skills = (%all_skills, %$repo_skills);
        }
    }
    else {
        # Scan cache directory directly
        return {} unless -d $self->{cache_dir};
        
        opendir my $dh, $self->{cache_dir} or return {};
        my @repos = grep { !/^\./ && -d File::Spec->catdir($self->{cache_dir}, $_) } readdir($dh);
        closedir $dh;
        
        for my $repo_name (@repos) {
            my $repo_skills = $self->load_repo_skills($repo_name);
            %all_skills = (%all_skills, %$repo_skills);
        }
    }
    
    log_debug('RepositoryLoader', "Loaded " . scalar(keys %all_skills) . " repository skills");
    
    return \%all_skills;
}

=head2 load_repo_skills

Load skills from a specific cached repository.

Arguments:
- $repo_name: Repository name (directory name in cache)

Returns: Hashref of skills keyed by name

=cut

sub load_repo_skills {
    my ($self, $repo_name) = @_;
    
    my $repo_path = File::Spec->catdir($self->{cache_dir}, $repo_name);
    return {} unless -d $repo_path;
    
    my %skills;
    
    # Detect repository layout and find skills
    my $skill_files = $self->_discover_skills($repo_path);
    
    for my $skill_md (@$skill_files) {
        my $parsed = $self->_parse_skill_md($skill_md, $repo_name);
        next unless $parsed && $parsed->{name};
        
        # Handle name collisions by prefixing with repo name
        my $skill_name = $parsed->{name};
        if ($skills{$skill_name}) {
            $skill_name = "${repo_name}/${skill_name}";
            $parsed->{name} = $skill_name;
        }
        
        $skills{$skill_name} = $parsed;
    }
    
    log_debug('RepositoryLoader', "Loaded " . scalar(keys %skills) . 
        " skills from '$repo_name'");
    
    return \%skills;
}

=head2 read_skill_content

Read the full content of a SKILL.md file.

Arguments:
- $skill_md_path: Path to SKILL.md file

Returns: String content or undef on error

=cut

sub read_skill_content {
    my ($self, $skill_md_path) = @_;
    
    return undef unless $skill_md_path && -f $skill_md_path;
    
    open my $fh, '<:encoding(UTF-8)', $skill_md_path or do {
        log_debug('RepositoryLoader', "Cannot read $skill_md_path: $!");
        return undef;
    };
    my $content = do { local $/; <$fh> };
    close $fh;
    
    return $content;
}

=head2 read_skill_resources

Read additional resource files from a skill directory.

Arguments:
- $skill_dir: Directory containing the skill
- $filename: Resource filename to read

Returns: String content or undef

=cut

sub read_skill_resource {
    my ($self, $skill_dir, $filename) = @_;
    
    my $path = File::Spec->catfile($skill_dir, $filename);
    return $self->read_skill_content($path);
}

=head2 list_skill_resources

List all resource files in a skill directory (excluding SKILL.md).

Arguments:
- $skill_dir: Directory containing the skill

Returns: Arrayref of filenames

=cut

sub list_skill_resources {
    my ($self, $skill_dir) = @_;
    
    return [] unless -d $skill_dir;
    
    opendir my $dh, $skill_dir or return [];
    my @files = grep {
        $_ ne '.' && $_ ne '..' && $_ ne 'SKILL.md' && 
        -f File::Spec->catfile($skill_dir, $_)
    } readdir($dh);
    closedir $dh;
    
    # Also check for scripts/ and references/ subdirectories
    for my $subdir (qw(scripts references assets)) {
        my $sub_path = File::Spec->catdir($skill_dir, $subdir);
        next unless -d $sub_path;
        
        opendir my $sdh, $sub_path or next;
        my @sub_files = grep {
            $_ ne '.' && $_ ne '..' && -f File::Spec->catfile($sub_path, $_)
        } readdir($sdh);
        closedir $sdh;
        
        push @files, map { "$subdir/$_" } @sub_files;
    }
    
    return \@files;
}

=head2 _discover_skills

Discover SKILL.md files in a repository, handling all three layouts.

Arguments:
- $repo_path: Path to the repository root

Returns: Arrayref of SKILL.md file paths

=cut

sub _discover_skills {
    my ($self, $repo_path) = @_;
    
    my @skill_files;
    
    # Check for single-skill repo (SKILL.md at root)
    my $root_skill = File::Spec->catfile($repo_path, 'SKILL.md');
    if (-f $root_skill) {
        push @skill_files, $root_skill;
        # Don't return early - there might be more skills in subdirectories
    }
    
    # Scan for skill directories (directories containing SKILL.md)
    $self->_scan_for_skills($repo_path, \@skill_files, 0);
    
    return \@skill_files;
}

=head2 _scan_for_skills

Recursively scan a directory for skill folders.

Arguments:
- $dir: Directory to scan
- $results: Arrayref to append found paths to
- $depth: Current recursion depth (max 3)

=cut

sub _scan_for_skills {
    my ($self, $dir, $results, $depth) = @_;
    
    # Limit recursion depth to avoid scanning deep into .git etc.
    return if $depth > 3;
    return unless -d $dir;
    
    opendir my $dh, $dir or return;
    my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir $dh;
    
    for my $entry (@entries) {
        next if $entry eq '.git';
        
        my $path = File::Spec->catdir($dir, $entry);
        next unless -d $path;
        
        my $skill_md = File::Spec->catfile($path, 'SKILL.md');
        
        if (-f $skill_md) {
            # Found a skill directory
            push @$results, $skill_md;
            # Don't recurse into skill directories - they might have
            # their own sub-skills that would be confusing
        }
        else {
            # Recurse into non-skill directories
            $self->_scan_for_skills($path, $results, $depth + 1);
        }
    }
}

=head2 _parse_skill_md

Parse a SKILL.md file, extracting YAML frontmatter and body.

Arguments:
- $skill_md_path: Path to SKILL.md
- $repo_name: Source repository name

Returns: Hashref with name, description, prompt, type, source_repo, 
         skill_path, skill_dir, readonly. Returns undef on parse failure.

=cut

sub _parse_skill_md {
    my ($self, $skill_md_path, $repo_name) = @_;
    
    my $content = $self->read_skill_content($skill_md_path);
    return undef unless defined $content;
    
    # Parse YAML frontmatter
    my $frontmatter = {};
    my $body = $content;
    
    if ($content =~ /\A---\s*\n(.*?)\n---\s*\n(.*)\z/s) {
        my $yaml_text = $1;
        $body = $2;
        
        $frontmatter = $self->_parse_yaml_frontmatter($yaml_text);
    }
    
    # Determine skill name
    my $name = $frontmatter->{name};
    unless ($name) {
        # Derive from directory name
        my ($vol, $dir, $file) = File::Spec->splitpath($skill_md_path);
        $dir =~ s|[\\/]+$||;  # Remove trailing separator
        my @parts = File::Spec->splitdir($dir);
        $name = $parts[-1] || 'unknown-skill';
        $name =~ s/[^a-zA-Z0-9_-]//g;  # Sanitize
    }
    
    # Normalize name to lowercase with hyphens
    $name = lc($name);
    $name =~ s/\s+/-/g;
    $name =~ s/_/-/g;
    
    my $description = $frontmatter->{description} || '';
    
    # Get the skill directory (parent of SKILL.md)
    my ($vol, $dir_path, $file) = File::Spec->splitpath($skill_md_path);
    $dir_path =~ s|[\\/]+$||;
    my $skill_dir = File::Spec->catpath($vol, $dir_path, '');
    $skill_dir =~ s|[\\/]+$||;
    
    return {
        name => $name,
        description => $description,
        prompt => $content,  # Full content including frontmatter
        type => 'repository',
        source_repo => $repo_name,
        skill_path => $skill_md_path,
        skill_dir => $skill_dir,
        readonly => 1,
        license => $frontmatter->{license} || '',
    };
}

=head2 _parse_yaml_frontmatter

Parse simple YAML frontmatter (key: value pairs only).

This is a lightweight parser that handles the common frontmatter format
used by SKILL.md files. It does not support nested structures, arrays,
or complex YAML features.

Arguments:
- $yaml_text: YAML text to parse

Returns: Hashref of key-value pairs

=cut

sub _parse_yaml_frontmatter {
    my ($self, $yaml_text) = @_;
    
    my %data;
    
    for my $line (split /\n/, $yaml_text) {
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;
        next unless $line;
        next if $line =~ /^#/;  # Comments
        
        # Match key: value patterns
        if ($line =~ /^(\w[\w-]*)\s*:\s*(.+)$/) {
            my ($key, $value) = ($1, $2);
            
            # Strip surrounding quotes
            $value =~ s/^["']//;
            $value =~ s/["']$//;
            
            # Strip inline comments (after # not inside quotes)
            $value =~ s/\s+#.*$// unless $value =~ /["']/;
            
            $data{$key} = $value;
        }
    }
    
    return \%data;
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

Copyright (c) 2026 CLIO Project

=cut
1;
