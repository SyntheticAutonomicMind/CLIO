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

BEGIN {
    use FindBin qw($RealBin);
    use lib "$RealBin/../../lib";
}

use CLIO::Core::SkillManager;
use CLIO::Core::Config;

my $tests = 0;
my $passed = 0;

sub ok_test {
    my ($name, $cond) = @_;
    $tests++;
    if ($cond) { $passed++; diag("ok $tests - $name"); }
    else       { diag("FAIL: $name"); }
}

# Set up temp dirs so we don't pollute the user's actual config.
my $tmpdir = tempdir(CLEANUP => 1);
$ENV{CLIO_USER_SKILLS} = File::Spec->catfile($tmpdir, 'user', 'skills.json');
my $project_dir = File::Spec->catfile($tmpdir, 'project');
my $clio_dir = File::Spec->catfile($project_dir, '.clio');
my $project_skills_file = File::Spec->catfile($clio_dir, 'skills.json');
my $freeform_dir = File::Spec->catfile($clio_dir, 'skills');

# Create the .clio dir so _has_project_scope returns true.
require File::Path;
File::Path::make_path($clio_dir, { mode => 0700 });

# --- Config: auto_create_skills default ---
my $config = CLIO::Core::Config->new();
my $cfg = $config->get_all();
ok_test('Config has auto_create_skills', exists $cfg->{auto_create_skills});
ok_test('auto_create_skills defaults to 1', $cfg->{auto_create_skills} == 1);

# --- SkillManager: add_freeform_skill ---
my $sm = CLIO::Core::SkillManager->new(
    debug => 0,
    project_skills_file => $project_skills_file,
    freeform_project_dir => $freeform_dir,
);

# Test successful creation
my $skill_content = <<'SKILL';
---
name: test-auto-skill
description: "Use this skill when you need to test something"
---
# Test Skill

1. Do this thing
2. Then do that thing

* Do not skip validation
SKILL

my $result = $sm->add_freeform_skill('test-auto-skill', 'Use this skill when testing', $skill_content);
ok_test('add_freeform_skill: success', $result->{success});
ok_test('add_freeform_skill: returns path', defined $result->{path} && -f $result->{path});
ok_test('add_freeform_skill: path ends with .md', $result->{path} =~ /\.md$/);
ok_test('add_freeform_skill: skill returned', defined $result->{skill});
ok_test('add_freeform_skill: name set', $result->{skill}{name} eq 'test-auto-skill');
ok_test('add_freeform_skill: scope is freeform', $result->{skill}{scope} eq 'freeform');
ok_test('add_freeform_skill: type is freeform', $result->{skill}{type} eq 'freeform');
ok_test('add_freeform_skill: readonly set', $result->{skill}{readonly});

# Test duplicate name rejection (shadowing builtin)
ok_test('add_freeform_skill: rejects builtin name',
    !$sm->add_freeform_skill('init', 'desc', 'content')->{success});

# Test invalid name
ok_test('add_freeform_skill: rejects invalid name with spaces',
    !$sm->add_freeform_skill('bad name', 'desc', 'content')->{success});

# Test empty content
ok_test('add_freeform_skill: rejects empty content',
    !$sm->add_freeform_skill('empty-skill', 'desc', '')->{success});

# Test session scope rejection
ok_test('add_freeform_skill: rejects session scope',
    !$sm->add_freeform_skill('session-skill', 'desc', 'content', scope => 'session')->{success});

# Test reload picks up the file
$sm->reload();
ok_test('add_freeform_skill: skill available after reload',
    defined $sm->get_skill('test-auto-skill'));
ok_test('add_freeform_skill: name parsed from frontmatter',
    $sm->get_skill('test-auto-skill')->{name} eq 'test-auto-skill');

# --- SkillOperations: create operation ---
# We can't easily test the full Tool pipeline, but we can verify the
# SkillManager.add_freeform_skill works with description handling.
my $sm2 = CLIO::Core::SkillManager->new(
    debug => 0,
    project_skills_file => $project_skills_file,
    freeform_project_dir => $freeform_dir,
);

my $content2 = <<'SKILL2';
---
name: debug-checklist
description: "Use this skill when debugging production issues"
---
# Debug Checklist

1. Check logs
2. Verify config
3. Restart service

* Do not skip step 2
SKILL2

my $r2 = $sm2->add_freeform_skill('debug-checklist', 'Use this skill when debugging', $content2);
ok_test('SkillOperations create path: success', $r2->{success});
ok_test('SkillOperations create path: file written', -f $r2->{path});
ok_test('SkillOperations create path: file contains name',
    do { local $/; open my $fh, '<', $r2->{path}; my $c = <$fh>; close $fh; $c =~ /debug-checklist/ });

# --- /skills autocreate command handler ---
# Verify the Skills command handler has the autocreate action registered.
# We check the source rather than running the full UI.
{
    open my $fh, '<', File::Spec->catfile($RealBin, '..', '..', 'lib', 'CLIO', 'UI', 'Commands', 'Skills.pm')
        or die "Cannot read Skills.pm: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    ok_test('Skills.pm: handles autocreate action',
        $src =~ /autocreate/ && $src =~ /_handle_autocreate/);
    ok_test('Skills.pm: autocreate supports on/off',
        $src =~ /lc\(\$arg\)/ && $src =~ /eq 'on'/ && $src =~ /eq 'off'/);
    ok_test('Skills.pm: help text includes autocreate',
        $src =~ /autocreate \[on\|off\]/);
    ok_test('Skills.pm: uses config for setting',
        $src =~ /\$self->\{chat\}->\{config\}/);
}

# --- PromptBuilder: auto-skill section ---
{
    open my $fh, '<', File::Spec->catfile($RealBin, '..', '..', 'lib', 'CLIO', 'Core', 'PromptBuilder.pm')
        or die "Cannot read PromptBuilder.pm: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    ok_test('PromptBuilder: has auto_skill section',
        $src =~ /auto-skill creation guidance/);
    ok_test('PromptBuilder: has Skill Creation header',
        $src =~ /## Skill Creation/);
    ok_test('PromptBuilder: LTM-pattern protocol (You MUST framing)',
        $src =~ /You MUST:/);
    ok_test('PromptBuilder: has Check the catalog bullet',
        $src =~ /Check the catalog first/);
    ok_test('PromptBuilder: has Create on demand bullet',
        $src =~ /Create on demand/);
    ok_test('PromptBuilder: has Maintain when stale bullet',
        $src =~ /Maintain when stale/);
    ok_test('PromptBuilder: has Disable when noisy bullet',
        $src =~ /Disable when noisy/);
    ok_test('PromptBuilder: names interact tool for surfacing candidates',
        $src =~ /interact tool before\s*\n?\s*writing/);
    ok_test('PromptBuilder: anti-patterns guidance',
        $src =~ /Anti-patterns to avoid/);
    ok_test('PromptBuilder: storage mechanics (files are source of truth)',
        $src =~ /files are the source of truth/);
    ok_test('PromptBuilder: no inline JSON syntax (schema lives in tool description)',
        $src !~ /\{\"operation\": \"create\"/);
    ok_test('PromptBuilder: no inline parameter list (schema lives in tool description)',
        $src !~ /name=<kebab-slug>/);
    ok_test('PromptBuilder: respects config flag',
        $src =~ /auto_create_skills/);
    ok_test('PromptBuilder: respects skip_custom (incognito)',
        $src =~ /skip_custom/);
}

print "\n$passed/$tests tests passed\n";
exit($passed == $tests ? 0 : 1);
