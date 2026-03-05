#!/usr/bin/env perl
# Test: CLIO::Spec::Manager and CLIO::Util::YAML
# Tests the OpenSpec-compatible spec management system

use strict;
use warnings;
use utf8;
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname);

# Setup lib path
use FindBin;
use lib "$FindBin::Bin/../../lib";

use CLIO::Util::YAML qw(yaml_load yaml_load_file yaml_dump);
use CLIO::Spec::Manager;

my $tests_run = 0;
my $tests_pass = 0;

sub ok {
    my ($cond, $name) = @_;
    $tests_run++;
    if ($cond) {
        $tests_pass++;
        print "  ok - $name\n";
    } else {
        print "  FAIL - $name\n";
    }
}

sub is {
    my ($got, $expected, $name) = @_;
    $tests_run++;
    if (defined $got && defined $expected && $got eq $expected) {
        $tests_pass++;
        print "  ok - $name\n";
    } else {
        $got //= '<undef>';
        $expected //= '<undef>';
        print "  FAIL - $name (got: '$got', expected: '$expected')\n";
    }
}

# --- YAML Tests ---

print "\n=== YAML Parser Tests ===\n\n";

# Simple key-value
{
    my $data = yaml_load("name: test\nversion: 1\n");
    is($data->{name}, 'test', 'yaml: simple string value');
    is($data->{version}, 1, 'yaml: numeric value');
}

# Boolean values
{
    my $data = yaml_load("enabled: true\ndisabled: false\n");
    ok($data->{enabled}, 'yaml: boolean true');
    ok(!$data->{disabled}, 'yaml: boolean false');
}

# Block scalar
{
    my $data = yaml_load("text: |\n  line 1\n  line 2\n  line 3\n");
    ok($data->{text} =~ /line 1/, 'yaml: block scalar contains line 1');
    ok($data->{text} =~ /line 3/, 'yaml: block scalar contains line 3');
}

# Simple array
{
    my $data = yaml_load("items:\n  - apple\n  - banana\n  - cherry\n");
    is(ref $data->{items}, 'ARRAY', 'yaml: array is arrayref');
    is(scalar @{$data->{items}}, 3, 'yaml: array has 3 items');
    is($data->{items}[0], 'apple', 'yaml: first array item');
}

# Inline array
{
    my $data = yaml_load("tags: [one, two, three]\n");
    is(ref $data->{tags}, 'ARRAY', 'yaml: inline array is arrayref');
    is(scalar @{$data->{tags}}, 3, 'yaml: inline array has 3 items');
}

# Nested mapping
{
    my $data = yaml_load("apply:\n  requires:\n    - tasks\n  tracks: tasks.md\n");
    is(ref $data->{apply}, 'HASH', 'yaml: nested mapping is hashref');
    is($data->{apply}{tracks}, 'tasks.md', 'yaml: nested scalar value');
    is(ref $data->{apply}{requires}, 'ARRAY', 'yaml: nested array');
    is($data->{apply}{requires}[0], 'tasks', 'yaml: nested array value');
}

# Array of hashes (artifacts)
{
    my $yaml = <<'YAML';
artifacts:
  - id: proposal
    generates: proposal.md
    description: Initial proposal
    requires: []
  - id: specs
    generates: specs/**/*.md
    requires:
      - proposal
YAML
    my $data = yaml_load($yaml);
    is(ref $data->{artifacts}, 'ARRAY', 'yaml: artifacts is array');
    is(scalar @{$data->{artifacts}}, 2, 'yaml: 2 artifacts');
    is($data->{artifacts}[0]{id}, 'proposal', 'yaml: first artifact id');
    is($data->{artifacts}[0]{generates}, 'proposal.md', 'yaml: first artifact generates');
    is($data->{artifacts}[1]{id}, 'specs', 'yaml: second artifact id');
    is(ref $data->{artifacts}[1]{requires}, 'ARRAY', 'yaml: second artifact requires is array');
    is($data->{artifacts}[1]{requires}[0], 'proposal', 'yaml: second artifact depends on proposal');
}

# Array of hashes with block scalar values
{
    my $yaml = <<'YAML';
artifacts:
  - id: proposal
    generates: proposal.md
    instruction: |
      Create a proposal.
      Include motivation.
    requires: []
  - id: design
    generates: design.md
    instruction: |
      Create a design doc.
    requires:
      - proposal
YAML
    my $data = yaml_load($yaml);
    is(scalar @{$data->{artifacts}}, 2, 'yaml: 2 artifacts with block scalars');
    ok($data->{artifacts}[0]{instruction} =~ /Create a proposal/, 'yaml: block scalar in array item');
    ok($data->{artifacts}[0]{instruction} =~ /Include motivation/, 'yaml: block scalar multi-line');
    ok($data->{artifacts}[1]{instruction} =~ /Create a design/, 'yaml: second block scalar');
    is($data->{artifacts}[1]{requires}[0], 'proposal', 'yaml: requires after block scalar');
}

# Dump and reload
{
    my $original = { name => 'test', version => '1', schema => 'spec-driven' };
    my $yaml = yaml_dump($original);
    my $reloaded = yaml_load($yaml);
    is($reloaded->{name}, 'test', 'yaml: dump/reload name');
    is($reloaded->{schema}, 'spec-driven', 'yaml: dump/reload schema');
}

# Comments
{
    my $data = yaml_load("# This is a comment\nname: test # inline\n");
    is($data->{name}, 'test', 'yaml: strips comments');
}

# Real OpenSpec config.yaml
if (-f 'reference/OpenSpec/openspec/config.yaml') {
    my $data = yaml_load_file('reference/OpenSpec/openspec/config.yaml');
    is($data->{schema}, 'spec-driven', 'yaml: real OpenSpec config schema');
    ok(defined $data->{context}, 'yaml: real OpenSpec config has context');
    is(ref $data->{rules}, 'HASH', 'yaml: real OpenSpec config rules is hash');
    is(ref $data->{rules}{specs}, 'ARRAY', 'yaml: real OpenSpec config rules.specs is array');
}

# Real OpenSpec schema.yaml
if (-f 'reference/OpenSpec/schemas/spec-driven/schema.yaml') {
    my $data = yaml_load_file('reference/OpenSpec/schemas/spec-driven/schema.yaml');
    is($data->{name}, 'spec-driven', 'yaml: real schema name');
    is(scalar @{$data->{artifacts}}, 4, 'yaml: real schema has 4 artifacts');
    
    for my $art (@{$data->{artifacts}}) {
        ok(defined $art->{id}, "yaml: real artifact has id ($art->{id})");
        ok(defined $art->{instruction} && length($art->{instruction}) > 50,
            "yaml: real artifact $art->{id} has instruction (" . length($art->{instruction} || '') . " chars)");
    }
}

# --- Spec Manager Tests ---

print "\n=== Spec Manager Tests ===\n\n";

my $test_dir = '/tmp/clio-spec-test-' . $$;
remove_tree($test_dir) if -d $test_dir;
make_path($test_dir);

{
    my $mgr = CLIO::Spec::Manager->new(project_root => $test_dir);
    
    # Not initialized yet
    ok(!$mgr->is_initialized(), 'manager: not initialized initially');
    
    # Init
    my $result = $mgr->init(context => "Test project\nPerl stack");
    ok($result->{success}, 'manager: init succeeds');
    ok($mgr->is_initialized(), 'manager: initialized after init');
    ok(-d "$test_dir/openspec/specs", 'manager: specs dir created');
    ok(-d "$test_dir/openspec/changes", 'manager: changes dir created');
    ok(-f "$test_dir/openspec/config.yaml", 'manager: config.yaml created');
    
    # Load config
    my $config = $mgr->load_config();
    is($config->{schema}, 'spec-driven', 'manager: config has schema');
    ok($config->{context} =~ /Test project/, 'manager: config has context');
    
    # Load built-in schema
    my $schema = $mgr->load_schema('spec-driven');
    is($schema->{name}, 'spec-driven', 'manager: schema name');
    is(scalar @{$schema->{artifacts}}, 4, 'manager: schema has 4 artifacts');
    
    # Create change - invalid name
    my $bad = $mgr->create_change('Bad Name');
    ok(!$bad->{success}, 'manager: rejects invalid change name');
    
    # Create change
    my $change = $mgr->create_change('add-dark-mode');
    ok($change->{success}, 'manager: create change succeeds');
    ok(-d "$test_dir/openspec/changes/add-dark-mode", 'manager: change dir created');
    ok(-f "$test_dir/openspec/changes/add-dark-mode/.openspec.yaml", 'manager: .openspec.yaml created');
    
    # Duplicate
    my $dup = $mgr->create_change('add-dark-mode');
    ok(!$dup->{success}, 'manager: rejects duplicate change');
    
    # List changes
    my @changes = $mgr->list_changes();
    is(scalar @changes, 1, 'manager: 1 active change');
    is($changes[0]{name}, 'add-dark-mode', 'manager: change name');
    
    # Change status
    my $status = $mgr->change_status('add-dark-mode');
    ok($status->{success}, 'manager: status succeeds');
    is(scalar @{$status->{artifacts}}, 4, 'manager: 4 artifacts in status');
    is($status->{artifacts}[0]{id}, 'proposal', 'manager: first artifact is proposal');
    is($status->{artifacts}[0]{status}, 'ready', 'manager: proposal is ready');
    ok(!$status->{apply_ready}, 'manager: not apply-ready yet');
    
    # Get artifact instructions
    my $instr = $mgr->get_artifact_instructions('add-dark-mode', 'proposal');
    ok($instr->{success}, 'manager: get instructions succeeds');
    ok(length($instr->{instruction}) > 0, 'manager: has instruction text');
    ok(length($instr->{template}) > 0, 'manager: has template');
    
    # Write a spec
    my $spec_result = $mgr->write_spec('dark-mode', "# dark-mode Specification\n\n## Requirements\n\n### Requirement: Theme Toggle\nThe system SHALL support light and dark themes.\n");
    ok($spec_result->{success}, 'manager: write spec succeeds');
    ok(-f "$test_dir/openspec/specs/dark-mode/spec.md", 'manager: spec file created');
    
    # Read it back
    my $read = $mgr->read_spec('dark-mode');
    ok($read->{success}, 'manager: read spec succeeds');
    ok($read->{content} =~ /Theme Toggle/, 'manager: spec content correct');
    
    # List specs
    my @specs = $mgr->list_specs();
    is(scalar @specs, 1, 'manager: 1 spec');
    is($specs[0]{name}, 'dark-mode', 'manager: spec name');
    
    # Create a tasks.md to test parsing
    my $tasks_content = <<'TASKS';
## 1. Infrastructure

- [ ] 1.1 Create ThemeContext
- [x] 1.2 Add CSS variables

## 2. Components

- [ ] 2.1 Create ThemeToggle
- [ ] 2.2 Add to settings
TASKS
    open my $fh, '>:encoding(UTF-8)', "$test_dir/openspec/changes/add-dark-mode/tasks.md"
        or die "Cannot write tasks.md: $!";
    print $fh $tasks_content;
    close $fh;
    
    # Parse tasks
    my @tasks = $mgr->parse_tasks('add-dark-mode');
    is(scalar @tasks, 4, 'manager: 4 tasks parsed');
    ok(!$tasks[0]{completed}, 'manager: task 1.1 not done');
    ok($tasks[1]{completed}, 'manager: task 1.2 is done');
    ok($tasks[0]{title} =~ /ThemeContext/, 'manager: task title correct');
    
    # Get spec context (for system prompt)
    my $ctx = $mgr->get_spec_context();
    ok(length($ctx) > 0, 'manager: spec context not empty');
    ok($ctx =~ /dark-mode/, 'manager: context mentions spec');
    ok($ctx =~ /add-dark-mode/, 'manager: context mentions change');
    
    # Archive
    my $archive = $mgr->archive_change('add-dark-mode');
    ok($archive->{success}, 'manager: archive succeeds');
    ok(!-d "$test_dir/openspec/changes/add-dark-mode", 'manager: change dir removed');
    ok(-d "$test_dir/openspec/changes/archive", 'manager: archive dir exists');
    
    # Verify archived
    my @post_changes = $mgr->list_changes();
    is(scalar @post_changes, 0, 'manager: no active changes after archive');
}

# Cleanup
remove_tree($test_dir);

# --- Results ---

print "\n" . "=" x 40 . "\n";
print "Results: $tests_pass/$tests_run passed\n";
print "=" x 40 . "\n\n";

exit($tests_pass == $tests_run ? 0 : 1);
