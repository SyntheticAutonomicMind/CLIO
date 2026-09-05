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

my $tests = 0;
my $passed = 0;

sub ok_test {
    my ($name, $cond) = @_;
    $tests++;
    if ($cond) { $passed++; diag("ok $tests - $name"); }
    else       { diag("FAIL: $name"); }
}

# Set up temp skills dir so we don't pollute the user's actual config.
my $tmpdir = tempdir(CLEANUP => 1);
$ENV{CLIO_USER_SKILLS} = File::Spec->catfile($tmpdir, 'skills.json');

my $sm = CLIO::Core::SkillManager->new(debug => 0);

# --- Skill existence ---
ok_test('init skill exists', $sm->get_skill('init') ? 1 : 0);
ok_test('init-with-prd skill exists', $sm->get_skill('init-with-prd') ? 1 : 0);

# --- Execute and capture rendered prompts ---
my $init_result = $sm->execute_skill('init', {});
ok_test('init skill executes successfully', $init_result->{success});

my $prd_result = $sm->execute_skill('init-with-prd', {});
ok_test('init-with-prd skill executes successfully', $prd_result->{success});

my $init_prompt = $init_result->{rendered_prompt};
my $prd_prompt = $prd_result->{rendered_prompt};

# --- Template URLs are referenced ---
my $tmpl_instructions = 'https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/docs/templates/instructions.md.template';
my $tmpl_agents = 'https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/docs/templates/AGENTS.md.template';

ok_test('init prompt references instructions template URL',
    $init_prompt =~ /\Q$tmpl_instructions\E/ ? 1 : 0);
ok_test('init prompt references AGENTS template URL',
    $init_prompt =~ /\Q$tmpl_agents\E/ ? 1 : 0);

ok_test('init-with-prd prompt references instructions template URL',
    $prd_prompt =~ /\Q$tmpl_instructions\E/ ? 1 : 0);
ok_test('init-with-prd prompt references AGENTS template URL',
    $prd_prompt =~ /\Q$tmpl_agents\E/ ? 1 : 0);

# --- Old raw URLs are gone ---
my $old_instructions = 'https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/.clio/instructions.md';
my $old_agents = 'https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/AGENTS.md';

ok_test('init prompt does NOT reference old instructions URL',
    $init_prompt =~ /\Q$old_instructions\E/ ? 0 : 1);
ok_test('init prompt does NOT reference old AGENTS URL',
    $init_prompt =~ /\Q$old_agents\E/ ? 0 : 1);

ok_test('init-with-prd prompt does NOT reference old instructions URL',
    $prd_prompt =~ /\Q$old_instructions\E/ ? 0 : 1);
ok_test('init-with-prd prompt does NOT reference old AGENTS URL',
    $prd_prompt =~ /\Q$old_agents\E/ ? 0 : 1);

# --- Init prompt no longer has inline markdown structure block ---
ok_test('init prompt does NOT have inline markdown structure',
    $init_prompt !~ /Use this structure from CLIO's AGENTS/ ? 1 : 0);

# --- Prompt text uses template language ---
ok_test('init prompt uses "template documents" heading',
    $init_prompt =~ /Fetch CLIO's Template Documents/ ? 1 : 0);

ok_test('init prompt says "fill-in-the-blank schema"',
    $init_prompt =~ /fill-in-the-blank schema/ ? 1 : 0);

ok_test('init prompt mentions [PLACEHOLDER] tokens',
    $init_prompt =~ /\[PLACEHOLDER\]/ ? 1 : 0);

# --- Template files exist on disk ---
my $repo_root = File::Spec->catfile($RealBin, '..', '..');
my $agents_tmpl = File::Spec->catfile($repo_root, 'docs', 'templates', 'AGENTS.md.template');
my $instr_tmpl = File::Spec->catfile($repo_root, 'docs', 'templates', 'instructions.md.template');

ok_test('AGENTS.md.template file exists', -f $agents_tmpl);
ok_test('instructions.md.template file exists', -f $instr_tmpl);

# --- AGENTS template has placeholder structure ---
if (-f $agents_tmpl) {
    open my $fh, '<:encoding(UTF-8)', $agents_tmpl or die $!;
    local $/;
    my $tmpl = <$fh>;
    close $fh;

    ok_test('AGENTS template has project overview section',
        $tmpl =~ /## Project Overview/ ? 1 : 0);
    ok_test('AGENTS template has quick setup section',
        $tmpl =~ /## Quick Setup/ ? 1 : 0);
    ok_test('AGENTS template has code style section',
        $tmpl =~ /## Code Style/ ? 1 : 0);
    ok_test('AGENTS template has testing section',
        $tmpl =~ /## Testing/ ? 1 : 0);
    ok_test('AGENTS template has commit format section',
        $tmpl =~ /## Commit Format/ ? 1 : 0);
    ok_test('AGENTS template has anti-patterns section',
        $tmpl =~ /## Anti-Patterns/ ? 1 : 0);
    ok_test('AGENTS template references .clio/instructions.md',
        $tmpl =~ /\.clio\/instructions\.md/ ? 1 : 0);
    ok_test('AGENTS template does NOT reference CLIO modules',
        $tmpl !~ /CLIO::/ ? 1 : 0);
}

# --- Instructions template exists and is generic ---
if (-f $instr_tmpl) {
    open my $fh, '<:encoding(UTF-8)', $instr_tmpl or die $!;
    local $/;
    my $tmpl = <$fh>;
    close $fh;

    ok_test('instructions template has Unbroken Method',
        $tmpl =~ /Unbroken Method/ ? 1 : 0);
    ok_test('instructions template references AGENTS.md',
        $tmpl =~ /AGENTS\.md/ ? 1 : 0);
    ok_test('instructions template does NOT reference system prompt',
        $tmpl !~ /system prompt/ ? 1 : 0);
}

# done_testing and the summary are emitted below
# (Test::More's done_testing would also work, but we want a final count).
print "\n$passed/$tests tests passed\n";

exit($passed == $tests ? 0 : 1);
