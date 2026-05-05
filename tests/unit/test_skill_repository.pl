#!/usr/bin/env perl
# test_skill_repository.pl - Unit tests for SkillRepository and RepositoryLoader

use strict;
use warnings;
use utf8;
use Test::More;
use File::Spec;
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);

# Setup test directory
my $test_dir = tempdir(CLEANUP => 1);
my $config_dir = File::Spec->catdir($test_dir, 'clio-config');
my $cache_dir = File::Spec->catdir($test_dir, 'skill-cache');
make_path($config_dir);
make_path($cache_dir);

# Override config paths for testing
local $CLIO::Util::ConfigPath::CONFIG_DIR_OVERRIDE = $config_dir;

# ============================================================
# Test SkillRepository
# ============================================================

use_ok('CLIO::Core::SkillRepository');

my $repos_config = File::Spec->catfile($config_dir, 'skill-repositories.json');

my $repo_mgr = CLIO::Core::SkillRepository->new(
    debug => 0,
    repos_config_file => $repos_config,
    cache_dir => $cache_dir,
);
ok($repo_mgr, 'SkillRepository created');

# Test add_repo
{
    my $result = $repo_mgr->add_repo('test-repo', 'https://github.com/example/test-skills');
    ok($result->{success}, 'add_repo succeeded');
    is($result->{repo}{name}, 'test-repo', 'repo name set');
    is($result->{repo}{url}, 'https://github.com/example/test-skills', 'repo url set');
    is($result->{repo}{branch}, 'main', 'default branch is main');
    ok($result->{repo}{enabled}, 'repo is enabled by default');
}

# Test duplicate add
{
    my $result = $repo_mgr->add_repo('test-repo', 'https://github.com/example/other');
    ok(!$result->{success}, 'duplicate add_repo fails');
    like($result->{error}, qr/already exists/, 'error message mentions already exists');
}

# Test invalid name
{
    my $result = $repo_mgr->add_repo('bad name!', 'https://github.com/example/test');
    ok(!$result->{success}, 'invalid name rejected');
}

# Test get_repo
{
    my $repo = $repo_mgr->get_repo('test-repo');
    ok($repo, 'get_repo returns repo');
    is($repo->{name}, 'test-repo', 'correct repo returned');
    
    my $missing = $repo_mgr->get_repo('nonexistent');
    ok(!$missing, 'get_repo returns undef for missing repo');
}

# Test list_repos
{
    my $repos = $repo_mgr->list_repos();
    is(scalar(@$repos), 1, 'list_repos returns 1 repo');
    
    $repo_mgr->add_repo('second-repo', 'https://github.com/example/second');
    $repos = $repo_mgr->list_repos();
    is(scalar(@$repos), 2, 'list_repos returns 2 repos after adding second');
}

# Test enable/disable
{
    my $result = $repo_mgr->disable_repo('test-repo');
    ok($result->{success}, 'disable_repo succeeded');
    my $repo = $repo_mgr->get_repo('test-repo');
    ok(!$repo->{enabled}, 'repo is disabled');
    
    $result = $repo_mgr->enable_repo('test-repo');
    ok($result->{success}, 'enable_repo succeeded');
    $repo = $repo_mgr->get_repo('test-repo');
    ok($repo->{enabled}, 'repo is enabled');
}

# Test remove_repo
{
    my $result = $repo_mgr->remove_repo('second-repo');
    ok($result->{success}, 'remove_repo succeeded');
    my $repos = $repo_mgr->list_repos();
    is(scalar(@$repos), 1, '1 repo after removal');
    ok(!$repo_mgr->get_repo('second-repo'), 'removed repo not found');
}

# Test config persistence
{
    my $repo_mgr2 = CLIO::Core::SkillRepository->new(
        debug => 0,
        repos_config_file => $repos_config,
        cache_dir => $cache_dir,
    );
    my $repo = $repo_mgr2->get_repo('test-repo');
    ok($repo, 'repo persisted and loaded on new instance');
    is($repo->{url}, 'https://github.com/example/test-skills', 'repo url persisted');
}

# ============================================================
# Test RepositoryLoader with mock skill files
# ============================================================

use_ok('CLIO::Core::RepositoryLoader');

# Create mock skill repository structure
my $mock_repo = File::Spec->catdir($cache_dir, 'mock-skills');
make_path($mock_repo);

# Type 1: Skills at repo root
my $skill_a_dir = File::Spec->catdir($mock_repo, 'skill-a');
make_path($skill_a_dir);
write_file(File::Spec->catfile($skill_a_dir, 'SKILL.md'), <<'SKILL_A');
---
name: skill-a
description: 'First test skill for unit testing'
license: MIT
---

# Skill A

This is the first test skill.
SKILL_A

my $skill_b_dir = File::Spec->catdir($mock_repo, 'skill-b');
make_path($skill_b_dir);
write_file(File::Spec->catfile($skill_b_dir, 'SKILL.md'), <<'SKILL_B');
---
name: skill-b
description: 'Second test skill for unit testing'
---

# Skill B

This is the second test skill.
SKILL_B

# Type 3: Single skill at repo root
my $single_repo = File::Spec->catdir($cache_dir, 'single-skill');
make_path($single_repo);
write_file(File::Spec->catfile($single_repo, 'SKILL.md'), <<'SINGLE');
---
name: single-skill
description: 'A single skill in a repo'
---

# Single Skill

This is a single skill repo.
SINGLE

# Type 2: Skills in subdirectory
my $subdir_repo = File::Spec->catdir($cache_dir, 'subdir-skills');
my $skills_subdir = File::Spec->catdir($subdir_repo, '.github', 'skills');
make_path($skills_subdir);
my $skill_c_dir = File::Spec->catdir($skills_subdir, 'skill-c');
make_path($skill_c_dir);
write_file(File::Spec->catfile($skill_c_dir, 'SKILL.md'), <<'SKILL_C');
---
name: skill-c
description: 'Skill in a subdirectory'
---

# Skill C

Nested skill.
SKILL_C

my $loader = CLIO::Core::RepositoryLoader->new(
    debug => 0,
    cache_dir => $cache_dir,
);
ok($loader, 'RepositoryLoader created');

# Test load_repo_skills for Type 1 (root-level skills)
{
    my $skills = $loader->load_repo_skills('mock-skills');
    ok($skills, 'load_repo_skills returned');
    is(scalar(keys %$skills), 2, 'found 2 skills in mock-skills');
    ok($skills->{'skill-a'}, 'skill-a found');
    ok($skills->{'skill-b'}, 'skill-b found');
    is($skills->{'skill-a'}{type}, 'repository', 'skill type is repository');
    is($skills->{'skill-a'}{source_repo}, 'mock-skills', 'source_repo set');
    is($skills->{'skill-a'}{description}, 'First test skill for unit testing', 'description parsed');
    ok($skills->{'skill-a'}{readonly}, 'repository skills are readonly');
}

# Test load_repo_skills for Type 3 (single skill)
{
    my $skills = $loader->load_repo_skills('single-skill');
    ok($skills, 'single skill repo loaded');
    is(scalar(keys %$skills), 1, 'found 1 skill in single-skill');
    ok($skills->{'single-skill'}, 'single-skill found');
}

# Test load_repo_skills for Type 2 (subdirectory skills)
{
    my $skills = $loader->load_repo_skills('subdir-skills');
    ok($skills, 'subdir skills repo loaded');
    is(scalar(keys %$skills), 1, 'found 1 skill in subdir-skills');
    ok($skills->{'skill-c'}, 'skill-c found in subdirectory');
}

# Test load_all_skills
{
    my $skills = $loader->load_all_skills();
    ok($skills, 'load_all_skills returned');
    is(scalar(keys %$skills), 4, 'found 4 skills total across all repos');
}

# Test read_skill_content
{
    my $skill_md = File::Spec->catfile($skill_a_dir, 'SKILL.md');
    my $content = $loader->read_skill_content($skill_md);
    ok($content, 'read_skill_content returned');
    like($content, qr/Skill A/, 'content contains expected text');
}

# Test list_skill_resources
{
    # Create a skill with resources
    my $res_dir = File::Spec->catdir($mock_repo, 'skill-with-resources');
    make_path($res_dir);
    write_file(File::Spec->catfile($res_dir, 'SKILL.md'), "---\nname: res-skill\n---\n\n# Res\n");
    make_path(File::Spec->catdir($res_dir, 'scripts'));
    write_file(File::Spec->catfile($res_dir, 'scripts', 'helper.sh'), "#!/bin/bash\necho hi\n");
    write_file(File::Spec->catfile($res_dir, 'README.md'), "# Readme\n");
    
    my $resources = $loader->list_skill_resources($res_dir);
    ok($resources, 'list_skill_resources returned');
    my %found = map { $_ => 1 } @$resources;
    ok($found{'README.md'}, 'README.md found as resource');
    ok($found{'scripts/helper.sh'}, 'scripts/helper.sh found as resource');
}

# ============================================================
# Test SkillManager integration
# ============================================================

use_ok('CLIO::Core::SkillManager');

# Create a SkillManager with the test cache
my $sm_config_dir = File::Spec->catdir($test_dir, 'sm-config');
make_path($sm_config_dir);

my $sm = CLIO::Core::SkillManager->new(
    debug => 0,
    user_skills_file => File::Spec->catfile($sm_config_dir, 'skills.json'),
);
ok($sm, 'SkillManager created');

# Test that repository skills are loaded
{
    my $skills = $sm->list_skills();
    ok($skills, 'list_skills returned');
    ok(exists $skills->{repository}, 'repository key exists in skills list');
}

# Test get_repo_manager
{
    my $rm = $sm->get_repo_manager();
    ok($rm, 'get_repo_manager returns instance');
    isa_ok($rm, 'CLIO::Core::SkillRepository');
}

# Test reload_repository_skills
{
    my $result = $sm->reload_repository_skills();
    ok(1, 'reload_repository_skills completed without error');
}

done_testing();

# Helper: write file
sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>:encoding(UTF-8)', $path or die "Cannot write $path: $!";
    print $fh $content;
    close $fh;
}