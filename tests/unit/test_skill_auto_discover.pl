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

use CLIO::Core::Config;
use CLIO::Core::SkillManager;
use CLIO::Core::PromptBuilder;
use CLIO::Tools::SkillOperations;

my $tests = 0;
my $passed = 0;

sub ok_test {
    my ($name, $cond) = @_;
    $tests++;
    if ($cond) { $passed++; diag("ok $tests - $name"); }
    else       { diag("FAIL: $name"); }
}

# Set up a temp user skills dir so we don't pollute the user's actual config.
my $tmpdir = tempdir(CLEANUP => 1);
$ENV{CLIO_USER_SKILLS} = File::Spec->catfile($tmpdir, 'skills.json');

# Add a known custom skill for catalog tests.
my $sm = CLIO::Core::SkillManager->new(debug => 0);
my $add = $sm->add_skill(
    'test-skill',
    "Hello \${name}, review this code for \${topic}.",
    description => 'Test skill for code review',
);
ok_test('add_skill succeeded', $add->{success} && $add->{prompt});
ok_test('add_skill extracted variables', scalar(@{$add->{prompt}{variables} // []}) == 2);

# Catalog includes the new skill with metadata.
my $catalog = $sm->list_skill_catalog();
ok_test('catalog is arrayref', ref($catalog) eq 'ARRAY');
my %by_name = map { $_->{name} => $_ } @$catalog;
ok_test('catalog has test-skill', exists $by_name{'test-skill'});
ok_test('catalog entry has type', defined $by_name{'test-skill'}{type});
ok_test('catalog entry has description', $by_name{'test-skill'}{description} =~ /Test skill/);
ok_test('catalog entry has variables',
    ref($by_name{'test-skill'}{variables}) eq 'ARRAY' &&
    scalar(@{$by_name{'test-skill'}{variables}}) == 2);

# get_skill_full returns the prompt and metadata.
my $full = $sm->get_skill_full('test-skill');
ok_test('get_skill_full returns hashref', ref($full) eq 'HASH');
ok_test('get_skill_full has prompt', length($full->{prompt}) > 0);
ok_test('get_skill_full has variables', scalar(@{$full->{variables}}) == 2);
ok_test('get_skill_full unknown returns undef', !defined $sm->get_skill_full('does-not-exist'));

# render_skill_content strips frontmatter and returns prompt body.
my $rendered = $sm->render_skill_content('test-skill');
ok_test('render_skill_content non-empty', length($rendered) > 0);
ok_test('render_skill_content unknown returns empty', $sm->render_skill_content('nope') eq '');

# Description truncation: install a long-description skill and verify cap.
my $long_desc = 'x' x 500;
my $add_long = $sm->add_skill('long-desc-skill', 'short body', description => $long_desc);
my $cap = $sm->list_skill_catalog(50);
my %cap_by = map { $_->{name} => $_ } @$cap;
ok_test('catalog description truncated to 50', length($cap_by{'long-desc-skill'}{description}) <= 50);

# Default cap is 200.
my $cap_default = $sm->list_skill_catalog();
my %cap_def_by = map { $_->{name} => $_ } @$cap_default;
ok_test('default catalog description truncated to 200',
    length($cap_def_by{'long-desc-skill'}{description}) <= 200);

# SkillOperations tool: list returns the catalog.
my $tool = CLIO::Tools::SkillOperations->new(debug => 0);
my $list_result = $tool->execute({ operation => 'list' });
ok_test('list_result success', $list_result->{success});
ok_test('list_result is arrayref', ref($list_result->{output} // []) eq 'ARRAY');
ok_test('list_result has at least one skill', scalar(@{$list_result->{output}}) >= 1);

# SkillOperations tool: load returns full content.
my $load_result = $tool->execute({ operation => 'load', name => 'test-skill' });
ok_test('load_result success', $load_result->{success});
ok_test('load_result has prompt', ref($load_result->{output}) eq 'HASH' && length($load_result->{output}{prompt}) > 0);
ok_test('load_result has variables', scalar(@{$load_result->{output}{variables}}) == 2);

# Load with missing name returns error.
my $load_err = $tool->execute({ operation => 'load' });
ok_test('load_result missing name error', !$load_err->{success});

# Load with invalid name returns error.
my $load_invalid = $tool->execute({ operation => 'load', name => 'evil/path' });
ok_test('load_result invalid name rejected', !$load_invalid->{success});

# Load unknown skill returns error.
my $load_unknown = $tool->execute({ operation => 'load', name => 'definitely-not-a-skill' });
ok_test('load_result unknown skill error', !$load_unknown->{success});

# PromptBuilder skill section: with auto_discover_skills=1, catalog appears.
# We use a stub tool registry (empty) since we're testing only the skills section.
require CLIO::Tools::Registry;
my $registry = CLIO::Tools::Registry->new(debug => 0);

my $builder = CLIO::Core::PromptBuilder->new(
    debug => 0,
    tool_registry => $registry,
    auto_discover_skills => 1,
);
my $section = $builder->generate_skills_section();
ok_test('skills section non-empty when enabled', length($section) > 0);
ok_test('skills section includes test-skill', $section =~ /test-skill/);
ok_test('skills section includes description', $section =~ /Test skill/);
ok_test('skills section has guidance text', $section =~ /Auto-Discovery Enabled/);

# PromptBuilder skill section: disabled returns empty.
my $builder_off = CLIO::Core::PromptBuilder->new(
    debug => 0,
    tool_registry => $registry,
    auto_discover_skills => 0,
);
my $section_off = $builder_off->generate_skills_section();
ok_test('skills section empty when disabled', $section_off eq '');

# PromptBuilder with preloaded skills via env var.
# Set env BEFORE first call to generate_skills_section (caching).
my $blocks = [{
    name => 'injected-skill',
    content => "Injected prompt content for testing",
}];
require CLIO::Util::JSON;
$ENV{CLIO_PRELOADED_SKILLS} = CLIO::Util::JSON::encode_json($blocks);
my $builder_pre = CLIO::Core::PromptBuilder->new(
    debug => 0,
    tool_registry => $registry,
    auto_discover_skills => 1,
);
my $section_preload = $builder_pre->generate_skills_section();
ok_test('preloaded skills section has injected content', $section_preload =~ /Injected prompt content/);
ok_test('preloaded skills section labels block', $section_preload =~ /Pre-loaded Skills/);
delete $ENV{CLIO_PRELOADED_SKILLS};

# PromptBuilder skill section: caching works (second call returns same ref content).
my $section2 = $builder->generate_skills_section();
ok_test('skills section cached (same length)', length($section) == length($section2));

# Cleanup: remove the test skill so we don't leave behind state.
$sm->delete_skill('test-skill');
$sm->delete_skill('long-desc-skill');

# done_testing and the summary are emitted below
# (Test::More's done_testing would also work, but we want a final count).
print "\n$passed/$tests tests passed\n";

exit($passed == $tests ? 0 : 1);
