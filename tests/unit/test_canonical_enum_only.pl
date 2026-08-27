#!/usr/bin/env perl
# Test: FileOperations operation enum contains only canonical names, not short
# aliases. Short aliases are accepted as operation VALUES (via validate_operation
# + dispatch_table) but are NOT advertised in the schema enum sent to the LLM.
# Also verifies that short aliases like 'read' are NOT registered as tool-name
# aliases in the Registry (preventing the LLM from confusing them with tool names).
#
# Note: 'search' and 'delete' ARE in the Registry's OPERATION_ALIASES because
# they are canonical operations for MemoryOperations. They are NOT confusing
# because the LLM sees them in MemoryOperations' enum, not FileOperations'.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use lib '../../lib';
use CLIO::Tools::FileOperations;
use CLIO::Tools::Registry;

my ($pass, $fail) = (0, 0);
sub ok { my ($cond, $label) = @_; if ($cond) { $pass++; print "OK: $label\n"; } else { $fail++; print "FAIL: $label\n"; } }

my $tool = CLIO::Tools::FileOperations->new();
my $def = $tool->get_tool_definition();
my $enum = $def->{parameters}{properties}{operation}{enum};
my %enum_set = map { $_ => 1 } @$enum;

# --- Canonical names MUST be in the enum ---
my @canonical = qw(read_file list_dir file_exists get_file_info get_errors
    file_search grep_search semantic_search read_tool_result
    create_file write_file append_file replace_string multi_replace_string
    insert_at_line delete_file rename_file create_directory);

for my $name (@canonical) {
    ok(exists $enum_set{$name}, "canonical operation '$name' is in the schema enum");
}

# --- Short aliases must NOT be in the enum ---
my @short_aliases = qw(read list_directory exists stat_file find_files
    read_result create write append replace edit bulk_replace
    insert_line insert remove rename mv make_directory mkdir);

# Note: 'search' and 'delete' are excluded from this check because they are
# canonical operations for MemoryOperations (which legitimately appear in the
# Registry's OPERATION_ALIASES mapping to memory_operations).

for my $alias (@short_aliases) {
    ok(!exists $enum_set{$alias}, "short alias '$alias' is NOT in the schema enum");
}

# --- validate_operation must still accept short aliases ---
my @all_aliases = (@short_aliases, qw(search delete));
for my $alias (@all_aliases) {
    ok($tool->validate_operation($alias), "validate_operation accepts alias '$alias'");
}

# --- validate_operation must still accept canonical names ---
for my $name (@canonical) {
    ok($tool->validate_operation($name), "validate_operation accepts canonical '$name'");
}

# --- Registry: FileOperations-specific short aliases should NOT resolve as
#     tool-name aliases. (search/delete are excluded - see note above.) ---
my $registry = CLIO::Tools::Registry->new();
$registry->register_tool($tool);

for my $alias (@short_aliases) {
    my $info = $registry->get_alias_info($alias);
    ok(!defined $info, "Registry does NOT map short alias '$alias' to a tool (no tool-name confusion)");
}

# --- Registry: canonical FileOperations names DO resolve as tool-name aliases ---
for my $name (qw(read_file write_file list_dir grep_search create_directory delete_file rename_file)) {
    my $info = $registry->get_alias_info($name);
    ok(defined $info && $info->{tool} eq 'file_operations',
       "Registry maps canonical '$name' -> file_operations");
}

# --- operation_aliases field exists on FileOperations ---
ok(ref($tool->{operation_aliases}) eq 'ARRAY', "FileOperations has operation_aliases array");
my $alias_count = scalar(@{$tool->{operation_aliases}});
ok($alias_count == scalar(@all_aliases),
   "operation_aliases has " . scalar(@all_aliases) . " entries (got $alias_count)");

# --- get_tool_definition enum count matches canonical-only ---
ok(scalar(@$enum) == scalar(@canonical),
   "schema enum has " . scalar(@canonical) . " entries (canonical only, got " . scalar(@$enum) . ")");

print "\nPassed: $pass\n";
print "Failed: $fail\n";
exit($fail == 0 ? 0 : 1);
