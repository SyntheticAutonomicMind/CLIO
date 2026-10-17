#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);

BEGIN {
    use FindBin qw($RealBin);
    use lib "$RealBin/../../lib";
}

use CLIO::Core::SkillManager;

my $tests = 0;
my $passed = 0;

sub ok_test {
    my ($name, $cond) = @_;
    $tests++;
    if ($cond) { $passed++; diag("ok $tests - $name"); }
    else       { diag("FAIL: $name"); }
}

my $repo_root = File::Spec->catfile($RealBin, '..', '..');
my $real_skills_dir = File::Spec->catfile($repo_root, 'skills');

# ── Test 1: System skills load from the repo's skills/ directory ──────────
{
    my $tmpdir = tempdir(CLEANUP => 1);
    local $ENV{CLIO_USER_SKILLS} = File::Spec->catfile($tmpdir, 'user.json');
    local $ENV{CLIO_SYSTEM_SKILLS_DIR} = $real_skills_dir;

    my $sm = CLIO::Core::SkillManager->new(debug => 0);
    my $by_scope = $sm->list_skills()->{by_scope};

    ok_test('system scope populated',
        scalar(@{$by_scope->{system} // []}) > 0);

    ok_test('init loaded as system type',
        ($sm->get_skill('init')->{type} // '') eq 'system');

    ok_test('init scope is system',
        ($sm->get_skill('init')->{scope} // '') eq 'system');

    ok_test('init source points to skills/init.md',
        ($sm->get_skill('init')->{source} // '') eq
        File::Spec->catfile($real_skills_dir, 'init.md'));

    ok_test('explain loaded as system type',
        ($sm->get_skill('explain')->{type} // '') eq 'system');

    ok_test('design loaded as system type',
        ($sm->get_skill('design')->{type} // '') eq 'system');

    my @expected = qw(init init-with-prd design design-review explain review test fix doc);
    for my $name (@expected) {
        ok_test("skill '$name' is system type",
            ($sm->get_skill($name)->{type} // '') eq 'system');
    }
}

# ── Test 2: --no-system-skills (CLIO_SKIP_SYSTEM_SKILLS) falls back to builtin ─
{
    my $tmpdir = tempdir(CLEANUP => 1);
    local $ENV{CLIO_USER_SKILLS} = File::Spec->catfile($tmpdir, 'user.json');
    local $ENV{CLIO_SYSTEM_SKILLS_DIR} = $real_skills_dir;
    local $ENV{CLIO_SKIP_SYSTEM_SKILLS} = 1;

    my $sm = CLIO::Core::SkillManager->new(debug => 0);

    ok_test('skip flag: init falls back to builtin',
        ($sm->get_skill('init')->{type} // '') eq 'builtin');

    ok_test('skip flag: no system skills loaded',
        scalar(@{$sm->list_skills()->{by_scope}{system} // []}) == 0);
}

# ── Test 3: Freeform user skill shadows system skill ──────────────────────
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $user_skills_dir = File::Spec->catdir($tmpdir, 'skills');
    make_path($user_skills_dir);

    # Write an override for 'init' in the user freeform dir
    my $override_path = File::Spec->catfile($user_skills_dir, 'init.md');
    open my $fh, '>:encoding(UTF-8)', $override_path;
    print $fh "---\nname: init\ndescription: User override of init\n---\nThis overrides the shipped init.\n";
    close $fh;

    my $tmp_user_json = File::Spec->catfile($tmpdir, 'user.json');
    open my $fh2, '>:encoding(UTF-8)', $tmp_user_json;
    print $fh2 "{}\n";
    close $fh2;

    local $ENV{CLIO_USER_SKILLS} = $tmp_user_json;
    local $ENV{CLIO_SYSTEM_SKILLS_DIR} = $real_skills_dir;

    my $sm = CLIO::Core::SkillManager->new(
        debug => 0,
        freeform_user_dir => $user_skills_dir,
    );

    ok_test('freeform override: init is freeform type',
        ($sm->get_skill('init')->{type} // '') eq 'freeform');

    ok_test('freeform override: init scope is user',
        ($sm->get_skill('init')->{scope} // '') eq 'user');

    ok_test('freeform override: init source is user .md',
        ($sm->get_skill('init')->{source} // '') eq $override_path);

    ok_test('freeform override: init prompt is the override',
        ($sm->get_skill('init')->{prompt} // '') =~ /This overrides the shipped init/);
}

# ── Test 4: System skill with no frontmatter gets a default description ──
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $sys_dir = File::Spec->catdir($tmpdir, 'sys-skills');
    make_path($sys_dir);

    my $no_fm_path = File::Spec->catfile($sys_dir, 'no-frontmatter.md');
    open my $fh, '>:encoding(UTF-8)', $no_fm_path;
    print $fh "This skill has no frontmatter.\nIt should still load.\n";
    close $fh;

    local $ENV{CLIO_SYSTEM_SKILLS_DIR} = $sys_dir;
    local $ENV{CLIO_USER_SKILLS} = File::Spec->catfile($tmpdir, 'user.json');

    my $sm = CLIO::Core::SkillManager->new(debug => 0);
    my $skill = $sm->get_skill('no-frontmatter');

    ok_test('system skill without frontmatter loads', $skill ? 1 : 0);
    ok_test('system skill without frontmatter has default description',
        ($skill->{description} // '') eq '(system skill, shipped with CLIO)') if $skill;
}

# ── Test 5: System skills directory with no .md files ─────────────────────
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $sys_dir = File::Spec->catdir($tmpdir, 'sys-skills');
    make_path($sys_dir);

    local $ENV{CLIO_SYSTEM_SKILLS_DIR} = $sys_dir;
    local $ENV{CLIO_USER_SKILLS} = File::Spec->catfile($tmpdir, 'user.json');

    my $sm = CLIO::Core::SkillManager->new(debug => 0);
    ok_test('empty system skills dir: no system skills loaded',
        scalar(@{$sm->list_skills()->{by_scope}{system} // []}) == 0);
}

# ── Test 6: CLIO_SYSTEM_SKILLS_DIR pointing at nonexistent dir ────────────
{
    my $tmpdir = tempdir(CLEANUP => 1);
    local $ENV{CLIO_SYSTEM_SKILLS_DIR} = File::Spec->catdir($tmpdir, 'does-not-exist');
    local $ENV{CLIO_USER_SKILLS} = File::Spec->catfile($tmpdir, 'user.json');

    my $sm = CLIO::Core::SkillManager->new(debug => 0);
    ok_test('nonexistent system dir: no system skills loaded',
        scalar(@{$sm->list_skills()->{by_scope}{system} // []}) == 0);
}

# ── Test 7: reload_system_skills works ────────────────────────────────────
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $sys_dir = File::Spec->catdir($tmpdir, 'sys-skills');
    make_path($sys_dir);

    my $skill_path = File::Spec->catfile($sys_dir, 'reloadtest.md');
    open my $fh, '>:encoding(UTF-8)', $skill_path;
    print $fh "---\nname: reloadtest\ndescription: Initial version\n---\nInitial content.\n";
    close $fh;

    local $ENV{CLIO_SYSTEM_SKILLS_DIR} = $sys_dir;
    local $ENV{CLIO_USER_SKILLS} = File::Spec->catfile($tmpdir, 'user.json');

    my $sm = CLIO::Core::SkillManager->new(debug => 0);
    ok_test('reload: skill loaded initially', $sm->get_skill('reloadtest') ? 1 : 0);
    ok_test('reload: initial description',
        ($sm->get_skill('reloadtest')->{description} // '') eq 'Initial version')
        if $sm->get_skill('reloadtest');

    # Modify the file on disk
    open my $fh2, '>:encoding(UTF-8)', $skill_path;
    print $fh2 "---\nname: reloadtest\ndescription: Updated version\n---\nUpdated content.\n";
    close $fh2;

    $sm->reload_system_skills();
    ok_test('reload: skill still present after reload', $sm->get_skill('reloadtest') ? 1 : 0);
    ok_test('reload: description updated',
        ($sm->get_skill('reloadtest')->{description} // '') eq 'Updated version')
        if $sm->get_skill('reloadtest');
}

print "\n$passed/$tests tests passed\n";
exit($passed == $tests ? 0 : 1);
