# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Spec::Manager;

use strict;
use warnings;
use utf8;

use Carp qw(croak);
use File::Path qw(make_path);
use File::Basename qw(dirname basename);
use File::Find qw(find);
use CLIO::Util::YAML qw(yaml_load yaml_load_file yaml_dump);
use CLIO::Core::Logger qw(log_debug log_info log_warning);

=head1 NAME

CLIO::Spec::Manager - OpenSpec-compatible spec management for CLIO

=head1 DESCRIPTION

Manages an OpenSpec-compatible C<openspec/> directory structure for spec-driven
development. Reads and writes the same file formats as the OpenSpec Node.js CLI,
enabling interoperability without requiring Node.js.

Lightweight approach: provides spec file management and context injection
without the full OpenSpec ceremony. Uses CLIO's existing checkpoint and todo
systems for the planning workflow.

=head1 SYNOPSIS

    use CLIO::Spec::Manager;

    my $mgr = CLIO::Spec::Manager->new(project_root => '.');

    # Initialize openspec/ directory
    $mgr->init();

    # List specs and changes
    my @specs = $mgr->list_specs();
    my @changes = $mgr->list_changes();

    # Create a new change
    $mgr->create_change('add-dark-mode');

    # Get status of a change
    my $status = $mgr->change_status('add-dark-mode');

    # Archive a completed change
    $mgr->archive_change('add-dark-mode');

    # Get spec context for system prompt
    my $context = $mgr->get_spec_context();

=cut

sub new {
    my ($class, %args) = @_;

    my $project_root = $args{project_root} || '.';
    my $self = {
        project_root => $project_root,
        openspec_dir => "$project_root/openspec",
        debug        => $args{debug} // 0,
    };

    bless $self, $class;
    return $self;
}

=head2 is_initialized()

Returns true if the project has an openspec/ directory.

=cut

sub is_initialized {
    my ($self) = @_;
    return -d $self->{openspec_dir};
}

=head2 init(%opts)

Initialize the openspec/ directory structure.

Options:
- schema: Schema name (default: 'spec-driven')
- context: Project context string
- force: Overwrite existing config

=cut

sub init {
    my ($self, %opts) = @_;

    my $dir = $self->{openspec_dir};
    my $schema = $opts{schema} || 'spec-driven';

    if (-d $dir && !$opts{force}) {
        return { success => 0, message => "OpenSpec already initialized at $dir" };
    }

    # Create directory structure
    make_path("$dir/specs", "$dir/changes");

    # Create config.yaml
    my $config = {
        schema => $schema,
    };
    $config->{context} = $opts{context} if $opts{context};

    my $config_yaml = yaml_dump($config);
    _write_file("$dir/config.yaml", $config_yaml);

    log_info('Spec', "Initialized openspec/ directory");
    return { success => 1, message => "OpenSpec initialized at $dir" };
}

=head2 load_config()

Load the project's openspec/config.yaml.

=cut

sub load_config {
    my ($self) = @_;

    my $config_path = "$self->{openspec_dir}/config.yaml";
    return {} unless -f $config_path;

    return yaml_load_file($config_path);
}

=head2 load_schema($name)

Load a schema definition. Checks project schemas first, then built-in.

=cut

sub load_schema {
    my ($self, $name) = @_;
    $name ||= 'spec-driven';

    # Check project-level schema first
    my $project_schema = "$self->{openspec_dir}/schemas/$name/schema.yaml";
    if (-f $project_schema) {
        return yaml_load_file($project_schema);
    }

    # Fall back to built-in
    return _builtin_schema($name);
}

=head2 list_specs()

List all spec domains in openspec/specs/.

Returns array of hashrefs: [{name => 'auth', path => 'openspec/specs/auth/spec.md'}]

=cut

sub list_specs {
    my ($self) = @_;

    my $specs_dir = "$self->{openspec_dir}/specs";
    return () unless -d $specs_dir;

    my @specs;
    opendir my $dh, $specs_dir or return ();
    while (my $entry = readdir $dh) {
        next if $entry =~ /^\./;
        my $spec_file = "$specs_dir/$entry/spec.md";
        if (-f $spec_file) {
            push @specs, {
                name => $entry,
                path => $spec_file,
            };
        }
    }
    closedir $dh;

    return sort { $a->{name} cmp $b->{name} } @specs;
}

=head2 list_changes()

List active changes in openspec/changes/ (excludes archive/).

Returns array of hashrefs with change metadata.

=cut

sub list_changes {
    my ($self) = @_;

    my $changes_dir = "$self->{openspec_dir}/changes";
    return () unless -d $changes_dir;

    my @changes;
    opendir my $dh, $changes_dir or return ();
    while (my $entry = readdir $dh) {
        next if $entry =~ /^\./;
        next if $entry eq 'archive';
        my $change_dir = "$changes_dir/$entry";
        next unless -d $change_dir;

        my $meta = $self->_load_change_meta($entry);
        push @changes, {
            name    => $entry,
            path    => $change_dir,
            schema  => $meta->{schema} || 'spec-driven',
            created => $meta->{created} || 'unknown',
        };
    }
    closedir $dh;

    return sort { $a->{name} cmp $b->{name} } @changes;
}

=head2 create_change($name)

Create a new change directory with metadata.

=cut

sub create_change {
    my ($self, $name) = @_;
    croak "Change name required" unless $name;

    # Validate kebab-case
    unless ($name =~ /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/) {
        return { success => 0, message => "Invalid change name '$name'. Use kebab-case (e.g., add-dark-mode)." };
    }

    my $change_dir = "$self->{openspec_dir}/changes/$name";
    if (-d $change_dir) {
        return { success => 0, message => "Change '$name' already exists." };
    }

    # Ensure openspec is initialized
    unless ($self->is_initialized()) {
        $self->init();
    }

    # Create change directory and specs subdirectory
    make_path("$change_dir/specs");

    # Load config for default schema
    my $config = $self->load_config();
    my $schema = $config->{schema} || 'spec-driven';

    # Write .openspec.yaml metadata
    my ($sec, $min, $hour, $mday, $mon, $year) = localtime;
    my $date = sprintf("%04d-%02d-%02d", $year + 1900, $mon + 1, $mday);

    _write_file("$change_dir/.openspec.yaml", yaml_dump({
        schema  => $schema,
        created => $date,
    }));

    log_info('Spec', "Created change: $name");
    return {
        success => 1,
        message => "Created change '$name' at $change_dir",
        path    => $change_dir,
        schema  => $schema,
    };
}

=head2 change_status($name)

Get the status of a change: which artifacts exist, which are ready.

=cut

sub change_status {
    my ($self, $name) = @_;
    croak "Change name required" unless $name;

    my $change_dir = "$self->{openspec_dir}/changes/$name";
    unless (-d $change_dir) {
        return { success => 0, message => "Change '$name' not found." };
    }

    my $meta = $self->_load_change_meta($name);
    my $schema = $self->load_schema($meta->{schema});
    my $artifacts = $schema->{artifacts} || [];

    my @status;
    for my $artifact (@$artifacts) {
        my $id = $artifact->{id};
        my $generates = $artifact->{generates};
        my $requires = $artifact->{requires} || [];

        # Check if artifact exists
        my $exists = _artifact_exists($change_dir, $generates);

        # Check if dependencies are met
        my $deps_met = 1;
        for my $dep (@$requires) {
            my $dep_art = _find_artifact($artifacts, $dep);
            if ($dep_art) {
                $deps_met = 0 unless _artifact_exists($change_dir, $dep_art->{generates});
            }
        }

        my $state = $exists ? 'done' : ($deps_met ? 'ready' : 'blocked');

        push @status, {
            id          => $id,
            generates   => $generates,
            description => $artifact->{description} || '',
            status      => $state,
            requires    => $requires,
        };
    }

    # Check if ready to apply
    my $apply_requires = $schema->{apply}{requires} || [];
    my $apply_ready = 1;
    for my $req (@$apply_requires) {
        my $found = 0;
        for my $s (@status) {
            if ($s->{id} eq $req && $s->{status} eq 'done') {
                $found = 1;
                last;
            }
        }
        $apply_ready = 0 unless $found;
    }

    return {
        success       => 1,
        name          => $name,
        schema        => $meta->{schema} || 'spec-driven',
        created       => $meta->{created},
        artifacts     => \@status,
        apply_ready   => $apply_ready,
    };
}

=head2 get_artifact_instructions($change_name, $artifact_id)

Get the instructions and template for creating an artifact.
Returns hashref with instruction, template, context, rules, output_path,
and dependency file contents.

=cut

sub get_artifact_instructions {
    my ($self, $change_name, $artifact_id) = @_;
    croak "Change name required" unless $change_name;
    croak "Artifact ID required" unless $artifact_id;

    my $change_dir = "$self->{openspec_dir}/changes/$change_name";
    unless (-d $change_dir) {
        return { success => 0, message => "Change '$change_name' not found." };
    }

    my $meta = $self->_load_change_meta($change_name);
    my $schema = $self->load_schema($meta->{schema});
    my $config = $self->load_config();

    my $artifact = _find_artifact($schema->{artifacts}, $artifact_id);
    unless ($artifact) {
        return { success => 0, message => "Artifact '$artifact_id' not found in schema." };
    }

    # Build output path
    my $output_path = "$change_dir/$artifact->{generates}";
    # For specs, the generates is a glob pattern
    if ($artifact->{generates} =~ /\*/) {
        $output_path = "$change_dir/specs/";  # directory for spec files
    }

    # Load dependency contents
    my %deps;
    for my $dep_id (@{$artifact->{requires} || []}) {
        my $dep_art = _find_artifact($schema->{artifacts}, $dep_id);
        if ($dep_art) {
            my $dep_path = "$change_dir/$dep_art->{generates}";
            if (-f $dep_path) {
                $deps{$dep_id} = _read_file($dep_path);
            }
        }
    }

    # Get template
    my $template = _builtin_template($artifact->{template} || "$artifact_id.md");

    return {
        success      => 1,
        artifact_id  => $artifact_id,
        instruction  => $artifact->{instruction} || '',
        template     => $template,
        output_path  => $output_path,
        context      => $config->{context} || '',
        rules        => ($config->{rules} && $config->{rules}{$artifact_id}) || [],
        dependencies => \%deps,
    };
}

=head2 read_spec($domain)

Read a spec file from openspec/specs/<domain>/spec.md.

=cut

sub read_spec {
    my ($self, $domain) = @_;
    croak "Domain name required" unless $domain;

    my $path = "$self->{openspec_dir}/specs/$domain/spec.md";
    unless (-f $path) {
        return { success => 0, message => "Spec '$domain' not found." };
    }

    return {
        success => 1,
        domain  => $domain,
        path    => $path,
        content => _read_file($path),
    };
}

=head2 write_spec($domain, $content)

Write a spec file to openspec/specs/<domain>/spec.md.

=cut

sub write_spec {
    my ($self, $domain, $content) = @_;
    croak "Domain name required" unless $domain;
    croak "Content required" unless defined $content;

    my $dir = "$self->{openspec_dir}/specs/$domain";
    make_path($dir) unless -d $dir;

    my $path = "$dir/spec.md";
    _write_file($path, $content);

    log_info('Spec', "Wrote spec: $domain");
    return { success => 1, path => $path };
}

=head2 archive_change($name)

Archive a completed change. Moves to changes/archive/ with date prefix.

=cut

sub archive_change {
    my ($self, $name) = @_;
    croak "Change name required" unless $name;

    my $change_dir = "$self->{openspec_dir}/changes/$name";
    unless (-d $change_dir) {
        return { success => 0, message => "Change '$name' not found." };
    }

    # Create archive directory
    my $archive_dir = "$self->{openspec_dir}/changes/archive";
    make_path($archive_dir) unless -d $archive_dir;

    # Date prefix
    my ($sec, $min, $hour, $mday, $mon, $year) = localtime;
    my $date = sprintf("%04d-%02d-%02d", $year + 1900, $mon + 1, $mday);
    my $archive_name = "$date-$name";
    my $dest = "$archive_dir/$archive_name";

    # Move
    rename($change_dir, $dest)
        or return { success => 0, message => "Failed to archive: $!" };

    log_info('Spec', "Archived change: $name -> archive/$archive_name");
    return {
        success      => 1,
        message      => "Archived '$name' to changes/archive/$archive_name",
        archive_path => $dest,
    };
}

=head2 parse_tasks($change_name)

Parse tasks.md for a change. Returns array of task hashrefs.

=cut

sub parse_tasks {
    my ($self, $change_name) = @_;

    my $tasks_path = "$self->{openspec_dir}/changes/$change_name/tasks.md";
    unless (-f $tasks_path) {
        return ();
    }

    my $content = _read_file($tasks_path);
    my @tasks;
    my $group = '';

    for my $line (split /\n/, $content) {
        if ($line =~ /^##\s+(.+)/) {
            $group = $1;
        }
        elsif ($line =~ /^-\s+\[([ xX])\]\s+(.+)/) {
            my $done = ($1 ne ' ') ? 1 : 0;
            push @tasks, {
                group       => $group,
                title       => $2,
                completed   => $done,
            };
        }
    }

    return @tasks;
}

=head2 get_spec_context()

Get a context string summarizing active specs and changes for system prompt injection.
Returns empty string if openspec/ not initialized.

=cut

sub get_spec_context {
    my ($self) = @_;

    return '' unless $self->is_initialized();

    my @specs = $self->list_specs();
    my @changes = $self->list_changes();

    return '' unless @specs || @changes;

    my @lines;
    push @lines, "## Project Specifications (OpenSpec)";
    push @lines, "";

    if (@specs) {
        push @lines, "### Active Specs";
        for my $s (@specs) {
            push @lines, "- **$s->{name}**: `$s->{path}`";
        }
        push @lines, "";
    }

    if (@changes) {
        push @lines, "### Active Changes";
        for my $c (@changes) {
            my $status = $self->change_status($c->{name});
            my $arts = $status->{artifacts} || [];
            my $done = grep { $_->{status} eq 'done' } @$arts;
            my $total = scalar @$arts;
            push @lines, "- **$c->{name}** ($done/$total artifacts) - schema: $c->{schema}";
        }
        push @lines, "";
    }

    push @lines, "Use `/spec` commands to manage specs and changes.";
    push @lines, "";

    return join("\n", @lines);
}

# --- Internal helpers ---

sub _load_change_meta {
    my ($self, $name) = @_;
    my $meta_path = "$self->{openspec_dir}/changes/$name/.openspec.yaml";
    return {} unless -f $meta_path;
    return yaml_load_file($meta_path);
}

sub _artifact_exists {
    my ($change_dir, $generates) = @_;

    if ($generates =~ /\*/) {
        # Glob pattern like specs/**/*.md - check if any spec files exist
        my $specs_dir = "$change_dir/specs";
        return 0 unless -d $specs_dir;
        my $found = 0;
        find(sub {
            $found = 1 if /\.md$/;
        }, $specs_dir);
        return $found;
    }

    return -f "$change_dir/$generates" ? 1 : 0;
}

sub _find_artifact {
    my ($artifacts, $id) = @_;
    for my $a (@$artifacts) {
        return $a if $a->{id} eq $id;
    }
    return undef;
}

sub _read_file {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or croak "Cannot read $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

sub _write_file {
    my ($path, $content) = @_;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;

    my $tmp = "$path.tmp.$$";
    open my $fh, '>:encoding(UTF-8)', $tmp or croak "Cannot write $tmp: $!";
    print $fh $content;
    close $fh;
    rename($tmp, $path) or croak "Cannot rename $tmp -> $path: $!";
}

# --- Built-in schema and templates ---

sub _builtin_schema {
    my ($name) = @_;

    if ($name eq 'spec-driven') {
        return {
            name        => 'spec-driven',
            version     => 1,
            description => 'Default OpenSpec workflow - proposal -> specs -> design -> tasks',
            artifacts   => [
                {
                    id          => 'proposal',
                    generates   => 'proposal.md',
                    description => 'Initial proposal document outlining the change',
                    template    => 'proposal.md',
                    instruction => _proposal_instruction(),
                    requires    => [],
                },
                {
                    id          => 'specs',
                    generates   => 'specs/**/*.md',
                    description => 'Detailed specifications for the change',
                    template    => 'spec.md',
                    instruction => _specs_instruction(),
                    requires    => ['proposal'],
                },
                {
                    id          => 'design',
                    generates   => 'design.md',
                    description => 'Technical design document with implementation details',
                    template    => 'design.md',
                    instruction => _design_instruction(),
                    requires    => ['proposal'],
                },
                {
                    id          => 'tasks',
                    generates   => 'tasks.md',
                    description => 'Implementation checklist with trackable tasks',
                    template    => 'tasks.md',
                    instruction => _tasks_instruction(),
                    requires    => ['specs', 'design'],
                },
            ],
            apply => {
                requires => ['tasks'],
                tracks   => 'tasks.md',
            },
        };
    }

    croak "Unknown built-in schema: $name";
}

sub _builtin_template {
    my ($name) = @_;

    my %templates = (
        'proposal.md' => <<'TMPL',
## Why

<!-- Explain the motivation for this change. What problem does this solve? Why now? -->

## What Changes

<!-- Describe what will change. Be specific about new capabilities, modifications, or removals. -->

## Capabilities

### New Capabilities
<!-- Capabilities being introduced. Each creates specs/<name>/spec.md -->

### Modified Capabilities
<!-- Existing capabilities whose REQUIREMENTS are changing. -->

## Impact

<!-- Affected code, APIs, dependencies, systems -->
TMPL
        'spec.md' => <<'TMPL',
## ADDED Requirements

### Requirement: <!-- requirement name -->
<!-- requirement text using SHALL/MUST -->

#### Scenario: <!-- scenario name -->
- **WHEN** <!-- condition -->
- **THEN** <!-- expected outcome -->
TMPL
        'design.md' => <<'TMPL',
## Context

<!-- Background and current state -->

## Goals / Non-Goals

**Goals:**
<!-- What this design aims to achieve -->

**Non-Goals:**
<!-- What is explicitly out of scope -->

## Decisions

<!-- Key design decisions and rationale -->

## Risks / Trade-offs

<!-- Known risks and trade-offs -->
TMPL
        'tasks.md' => <<'TMPL',
## 1. <!-- Task Group Name -->

- [ ] 1.1 <!-- Task description -->
- [ ] 1.2 <!-- Task description -->

## 2. <!-- Task Group Name -->

- [ ] 2.1 <!-- Task description -->
- [ ] 2.2 <!-- Task description -->
TMPL
    );

    return $templates{$name} || '';
}

# --- Instruction strings (matching OpenSpec spec-driven schema) ---

sub _proposal_instruction {
    return <<'INSTR';
Create the proposal document that establishes WHY this change is needed.

Sections:
- **Why**: 1-2 sentences on the problem or opportunity.
- **What Changes**: Bullet list of changes. Be specific.
- **Capabilities**: Identify which specs will be created or modified:
  - **New Capabilities**: Each becomes a new specs/<name>/spec.md
  - **Modified Capabilities**: Existing capabilities with requirement changes
- **Impact**: Affected code, APIs, dependencies, or systems.

Keep it concise (1-2 pages). Focus on the "why" not the "how".
INSTR
}

sub _specs_instruction {
    return <<'INSTR';
Create specification files that define WHAT the system should do.

Create one spec file per capability listed in the proposal.

Delta operations (use ## headers):
- **ADDED Requirements**: New capabilities
- **MODIFIED Requirements**: Changed behavior - include full updated content
- **REMOVED Requirements**: Deprecated features - include Reason and Migration

Format:
- Each requirement: ### Requirement: <name> followed by description
- Use SHALL/MUST for normative requirements
- Each scenario: #### Scenario: <name> with WHEN/THEN format
- Every requirement MUST have at least one scenario
INSTR
}

sub _design_instruction {
    return <<'INSTR';
Create the design document explaining HOW to implement the change.

Sections:
- **Context**: Background, current state, constraints
- **Goals / Non-Goals**: What this achieves and excludes
- **Decisions**: Key technical choices with rationale
- **Risks / Trade-offs**: Known limitations

Focus on architecture and approach, not line-by-line implementation.
INSTR
}

sub _tasks_instruction {
    return <<'INSTR';
Create the task list breaking down implementation work.

Guidelines:
- Group related tasks under ## numbered headings
- Each task MUST be a checkbox: - [ ] X.Y Task description
- Tasks should be small enough to complete in one session
- Order tasks by dependency
INSTR
}

=head1 POD

=head2 File Format Compatibility

This module reads and writes the same directory structure and file formats
as the OpenSpec Node.js CLI, enabling full interoperability.

=cut

1;
