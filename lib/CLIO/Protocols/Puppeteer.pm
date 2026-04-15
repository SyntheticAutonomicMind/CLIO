# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Protocols::Puppeteer;

use strict;
use warnings;
use utf8;

use Cwd qw(abs_path getcwd);
use File::Spec;
use CLIO::Util::JSON qw(encode_json decode_json);
use CLIO::Core::Logger qw(log_debug log_info log_warning);

=head1 NAME

CLIO::Protocols::Puppeteer - Multi-project orchestration via submodule-aware agent coordination

=head1 DESCRIPTION

Puppeteer detects git submodule topology and .clio/-enabled child projects,
providing the primary agent with a structured view of available projects and
their capabilities. It enables spawning child CLIO sessions that run inside
each project's directory with full access to that project's LTM, instructions,
and memory.

=head1 SYNOPSIS

    use CLIO::Protocols::Puppeteer;
    
    my $pup = CLIO::Protocols::Puppeteer->new(root => '.');
    my $topology = $pup->detect_topology();
    
    # Returns:
    # {
    #   root => '/path/to/ecosystem',
    #   projects => {
    #     'SAM' => { path => './SAM', has_clio => 1, ... },
    #     'ALICE'   => { path => './ALICE',   has_clio => 1, ... },
    #   },
    #   submodules => [...],
    # }

=cut

sub new {
    my ($class, %args) = @_;
    my $root = $args{root} || '.';
    
    return bless {
        root     => abs_path($root),
        projects => {},
        _scanned => 0,
    }, $class;
}

=head2 detect_topology()

Scans the current project for git submodules and directories containing
.clio/ configuration. Returns a hashref describing the project tree.

=cut

sub detect_topology {
    my ($self) = @_;
    
    my $root = $self->{root};
    log_debug('Puppeteer', "Scanning topology at: $root");
    
    my %projects;
    my @submodules;
    
    # Detect git submodules
    my $gitmodules = File::Spec->catfile($root, '.gitmodules');
    if (-f $gitmodules) {
        @submodules = $self->_parse_gitmodules($gitmodules);
        log_debug('Puppeteer', "Found %d submodules", scalar @submodules);
        
        for my $sm (@submodules) {
            my $path = File::Spec->catdir($root, $sm->{path});
            next unless -d $path;
            
            $projects{$sm->{name}} = {
                path       => $sm->{path},
                abs_path   => abs_path($path),
                source     => 'submodule',
                url        => $sm->{url},
                has_clio   => (-d File::Spec->catdir($path, '.clio') ? 1 : 0),
                has_ltm    => (-f File::Spec->catfile($path, '.clio', 'ltm.json') ? 1 : 0),
                has_instructions => (-f File::Spec->catfile($path, '.clio', 'instructions.md') ? 1 : 0),
            };
        }
    }
    
    # Scan for additional .clio/-enabled directories not in submodules
    if (opendir(my $dh, $root)) {
        while (my $entry = readdir($dh)) {
            next if $entry =~ /^\./;  # Skip hidden dirs
            my $path = File::Spec->catdir($root, $entry);
            next unless -d $path;
            next if exists $projects{$entry};  # Already found as submodule
            
            my $clio_dir = File::Spec->catdir($path, '.clio');
            if (-d $clio_dir) {
                $projects{$entry} = {
                    path       => $entry,
                    abs_path   => abs_path($path),
                    source     => 'directory',
                    has_clio   => 1,
                    has_ltm    => (-f File::Spec->catfile($clio_dir, 'ltm.json') ? 1 : 0),
                    has_instructions => (-f File::Spec->catfile($clio_dir, 'instructions.md') ? 1 : 0),
                };
            }
        }
        closedir($dh);
    }
    
    $self->{projects} = \%projects;
    $self->{_scanned} = 1;
    
    my $topology = {
        root       => $root,
        projects   => \%projects,
        submodules => \@submodules,
        count      => scalar(keys %projects),
    };
    
    log_info('Puppeteer', "Topology: %d projects detected", $topology->{count});
    
    return $topology;
}

=head2 get_project($name)

Returns project info by name, or undef if not found.

=cut

sub get_project {
    my ($self, $name) = @_;
    $self->detect_topology() unless $self->{_scanned};
    return $self->{projects}{$name};
}

=head2 list_projects()

Returns a list of project names.

=cut

sub list_projects {
    my ($self) = @_;
    $self->detect_topology() unless $self->{_scanned};
    return sort keys %{$self->{projects}};
}

=head2 project_summary()

Returns a human-readable summary of the detected topology, suitable
for injection into the agent's system prompt.

=cut

sub project_summary {
    my ($self) = @_;
    $self->detect_topology() unless $self->{_scanned};
    
    return undef unless keys %{$self->{projects}};
    
    my @lines;
    push @lines, "## Puppeteer Topology";
    push @lines, "";
    push @lines, "This project manages " . scalar(keys %{$self->{projects}}) . " child project(s):";
    push @lines, "";
    
    for my $name (sort keys %{$self->{projects}}) {
        my $p = $self->{projects}{$name};
        my @flags;
        push @flags, "LTM" if $p->{has_ltm};
        push @flags, "instructions" if $p->{has_instructions};
        push @flags, "submodule" if $p->{source} eq 'submodule';
        
        my $flag_str = @flags ? " [" . join(", ", @flags) . "]" : "";
        push @lines, "- **$name** ($p->{path})$flag_str";
    }
    
    push @lines, "";
    push @lines, "To delegate work to a project, spawn a sub-agent with working_dir:";
    push @lines, '```';
    push @lines, 'agent_operations(operation: "spawn", task: "...", working_dir: "./ProjectName")';
    push @lines, '```';
    push @lines, "The child agent will load that project's .clio/ context (LTM, instructions, memory).";
    
    return join("\n", @lines);
}

=head2 read_project_instructions($name)

Reads a project's .clio/instructions.md if it exists. Returns the content
or undef.

=cut

sub read_project_instructions {
    my ($self, $name) = @_;
    my $project = $self->get_project($name);
    return undef unless $project && $project->{has_instructions};
    
    my $path = File::Spec->catfile($project->{abs_path}, '.clio', 'instructions.md');
    return undef unless -f $path;
    
    open my $fh, '<:encoding(UTF-8)', $path or return undef;
    my $content = do { local $/; <$fh> };
    close $fh;
    
    return $content;
}

=head2 read_project_ltm($name)

Reads a project's .clio/ltm.json if it exists. Returns the parsed data
or undef.

=cut

sub read_project_ltm {
    my ($self, $name) = @_;
    my $project = $self->get_project($name);
    return undef unless $project && $project->{has_ltm};
    
    my $path = File::Spec->catfile($project->{abs_path}, '.clio', 'ltm.json');
    return undef unless -f $path;
    
    open my $fh, '<:encoding(UTF-8)', $path or return undef;
    my $content = do { local $/; <$fh> };
    close $fh;
    
    return eval { decode_json($content) };
}

# Parse .gitmodules file into array of { name, path, url }
sub _parse_gitmodules {
    my ($self, $file) = @_;
    
    open my $fh, '<:encoding(UTF-8)', $file or return ();
    
    my @modules;
    my $current;
    
    while (my $line = <$fh>) {
        chomp $line;
        
        if ($line =~ /^\[submodule\s+"([^"]+)"\]/) {
            $current = { name => $1 };
            push @modules, $current;
        }
        elsif ($current && $line =~ /^\s*path\s*=\s*(.+?)\s*$/) {
            $current->{path} = $1;
        }
        elsif ($current && $line =~ /^\s*url\s*=\s*(.+?)\s*$/) {
            $current->{url} = $1;
        }
    }
    
    close $fh;
    return @modules;
}

1;
