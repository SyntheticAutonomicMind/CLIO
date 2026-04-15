#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

test_puppeteer.pl - Unit tests for CLIO::Protocols::Puppeteer

=head1 DESCRIPTION

Tests topology detection from .gitmodules and .clio/ directories,
project summary generation, and project lookup by name.

=cut

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;

# Module loading
BEGIN { use_ok('CLIO::Protocols::Puppeteer') or BAIL_OUT("Cannot load Puppeteer"); }

# Helper: create a mock project tree
sub setup_tree {
    my $root = tempdir(CLEANUP => 1);
    return $root;
}

sub write_file {
    my ($path, $content) = @_;
    my $dir = File::Spec->catpath((File::Spec->splitpath($path))[0,1], '');
    make_path($dir) if $dir && !-d $dir;
    open my $fh, '>', $path or die "Cannot write $path: $!";
    print $fh ($content || '');
    close $fh;
}

# ============================================================================
# 1. Empty project - no topology
# ============================================================================

subtest 'Empty project has no topology' => sub {
    my $root = setup_tree();
    my $pup = CLIO::Protocols::Puppeteer->new(root => $root);
    
    ok($pup, 'Puppeteer object created');
    my $topo = $pup->detect_topology();
    
    is($topo->{count}, 0, 'No projects detected in empty dir');
    is_deeply($topo->{projects}, {}, 'Projects hash is empty');
};

# ============================================================================
# 2. Detects .clio/ child directories
# ============================================================================

subtest 'Detects .clio/ child directories' => sub {
    my $root = setup_tree();
    
    # Create a child project with .clio/
    my $child = File::Spec->catdir($root, 'project-alpha');
    make_path(File::Spec->catdir($child, '.clio'));
    
    my $pup = CLIO::Protocols::Puppeteer->new(root => $root);
    my $topo = $pup->detect_topology();
    
    is($topo->{count}, 1, 'Found 1 project');
    ok(exists $topo->{projects}{'project-alpha'}, 'Project named correctly');
    is($topo->{projects}{'project-alpha'}{source}, 'directory', 'Source is directory');
    ok(!$topo->{projects}{'project-alpha'}{has_ltm}, 'No LTM detected');
    ok(!$topo->{projects}{'project-alpha'}{has_instructions}, 'No instructions detected');
};

# ============================================================================
# 3. Detects LTM and instructions
# ============================================================================

subtest 'Detects LTM and instructions files' => sub {
    my $root = setup_tree();
    my $child = File::Spec->catdir($root, 'project-beta');
    make_path(File::Spec->catdir($child, '.clio'));
    
    write_file(File::Spec->catfile($child, '.clio', 'ltm.json'), '{"discoveries":[]}');
    write_file(File::Spec->catfile($child, '.clio', 'instructions.md'), '# Beta Instructions');
    
    my $pup = CLIO::Protocols::Puppeteer->new(root => $root);
    my $topo = $pup->detect_topology();
    
    is($topo->{count}, 1, 'Found 1 project');
    ok($topo->{projects}{'project-beta'}{has_ltm}, 'LTM detected');
    ok($topo->{projects}{'project-beta'}{has_instructions}, 'Instructions detected');
};

# ============================================================================
# 4. Detects .gitmodules
# ============================================================================

subtest 'Detects .gitmodules entries' => sub {
    my $root = setup_tree();
    
    write_file(File::Spec->catfile($root, '.gitmodules'), <<'EOF');
[submodule "sam-core"]
    path = libs/sam-core
    url = https://github.com/example/sam-core.git

[submodule "clio-plugins"]
    path = libs/clio-plugins
    url = git@github.com:example/clio-plugins.git
EOF
    
    # Create the submodule dirs with .clio/ in one
    my $sam = File::Spec->catdir($root, 'libs', 'sam-core');
    make_path(File::Spec->catdir($sam, '.clio'));
    write_file(File::Spec->catfile($sam, '.clio', 'ltm.json'), '{}');
    
    my $clio_plugins = File::Spec->catdir($root, 'libs', 'clio-plugins');
    make_path($clio_plugins);
    
    my $pup = CLIO::Protocols::Puppeteer->new(root => $root);
    my $topo = $pup->detect_topology();
    
    # sam-core has .clio/ so should be detected
    ok(exists $topo->{projects}{'sam-core'}, 'sam-core detected');
    is($topo->{projects}{'sam-core'}{source}, 'submodule', 'sam-core source is submodule');
    ok($topo->{projects}{'sam-core'}{has_ltm}, 'sam-core has LTM');
    
    # clio-plugins has no .clio/ but should show from submodule scan
    ok(exists $topo->{projects}{'clio-plugins'}, 'clio-plugins detected from .gitmodules');
    is($topo->{projects}{'clio-plugins'}{source}, 'submodule', 'clio-plugins source is submodule');
};

# ============================================================================
# 5. Multiple projects
# ============================================================================

subtest 'Multiple child projects' => sub {
    my $root = setup_tree();
    
    for my $name (qw(alpha bravo charlie)) {
        my $dir = File::Spec->catdir($root, $name);
        make_path(File::Spec->catdir($dir, '.clio'));
    }
    
    my $pup = CLIO::Protocols::Puppeteer->new(root => $root);
    my $topo = $pup->detect_topology();
    
    is($topo->{count}, 3, 'Found 3 projects');
    ok(exists $topo->{projects}{$_}, "Found project $_") for qw(alpha bravo charlie);
};

# ============================================================================
# 6. project_summary() generates markdown
# ============================================================================

subtest 'project_summary generates markdown' => sub {
    my $root = setup_tree();
    my $child = File::Spec->catdir($root, 'myproject');
    make_path(File::Spec->catdir($child, '.clio'));
    write_file(File::Spec->catfile($child, '.clio', 'ltm.json'), '{}');
    write_file(File::Spec->catfile($child, '.clio', 'instructions.md'), '# Instructions');
    
    my $pup = CLIO::Protocols::Puppeteer->new(root => $root);
    my $summary = $pup->project_summary();
    
    ok(defined $summary, 'Summary is defined');
    like($summary, qr/myproject/, 'Summary mentions project name');
    like($summary, qr/LTM|instructions/i, 'Summary mentions capabilities');
};

# ============================================================================
# 7. get_project() lookup
# ============================================================================

subtest 'get_project lookup' => sub {
    my $root = setup_tree();
    my $child = File::Spec->catdir($root, 'target-project');
    make_path(File::Spec->catdir($child, '.clio'));
    
    my $pup = CLIO::Protocols::Puppeteer->new(root => $root);
    
    my $found = $pup->get_project('target-project');
    ok($found, 'Found project by name');
    like($found->{path}, qr/target-project/, 'Path contains project name');
    
    my $missing = $pup->get_project('nonexistent');
    ok(!$missing, 'Returns undef for nonexistent project');
};

# ============================================================================
# 8. Ignores .clio/ in root (not a child project)
# ============================================================================

subtest 'Ignores root .clio/' => sub {
    my $root = setup_tree();
    make_path(File::Spec->catdir($root, '.clio'));
    write_file(File::Spec->catfile($root, '.clio', 'ltm.json'), '{}');
    
    my $pup = CLIO::Protocols::Puppeteer->new(root => $root);
    my $topo = $pup->detect_topology();
    
    is($topo->{count}, 0, 'Root .clio/ not counted as child project');
};

# ============================================================================
# 9. project_summary returns undef when no projects
# ============================================================================

subtest 'project_summary undef when empty' => sub {
    my $root = setup_tree();
    
    my $pup = CLIO::Protocols::Puppeteer->new(root => $root);
    my $summary = $pup->project_summary();
    
    ok(!defined $summary, 'Summary is undef when no projects');
};

# ============================================================================
# 10. read_project_instructions
# ============================================================================

subtest 'read_project_instructions' => sub {
    my $root = setup_tree();
    my $child = File::Spec->catdir($root, 'documented');
    make_path(File::Spec->catdir($child, '.clio'));
    write_file(File::Spec->catfile($child, '.clio', 'instructions.md'), "# My Project\n\nBuild with: make");
    
    my $pup = CLIO::Protocols::Puppeteer->new(root => $root);
    my $content = $pup->read_project_instructions('documented');
    
    ok(defined $content, 'Instructions read');
    like($content, qr/Build with: make/, 'Content matches');
    
    my $none = $pup->read_project_instructions('nonexistent');
    ok(!defined $none, 'Returns undef for nonexistent project');
};

done_testing();
