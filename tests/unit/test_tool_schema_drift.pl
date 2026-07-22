#!/usr/bin/env perl
# Test suite for tool schema/implementation drift detection.
#
# Cross-cuts every AI-callable tool under lib/CLIO/Tools/. For each
# parameter declared in a tool's schema, verifies SOME operation in
# the file actually reads it via $params->{name}. Drift between
# schema documentation and code consumers is exactly the class of
# bug that produced Issue 1 (get_errors paths), Issue 4 (grep_search
# directory) and Issue 3 (LTM shadow writes) in the 2026-07-21
# tools test - all of these declared params that the implementation
# never read.
#
# The check is per-file, not per-operation. A param declared in the
# tool-wide schema that some operation actually consumes passes; a
# param declared but never consumed anywhere fails.
#
# Limitations (heuristic):
# - Params forwarded through helpers (e.g., passed wholesale to a
#   sub that destructures them) may show as unreferenced. This is a
#   known false-positive class.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use File::Find;
use CLIO::Tools::Tool;

my $pass = 0;
my $fail = 0;
my $total = 0;

sub ok {
    my ($test, $description) = @_;
    $total++;
    if ($test) {
        $pass++;
        print "  ok $total - $description\n";
    } else {
        $fail++;
        print "  NOT ok $total - $description\n";
    }
}

my @tool_files;
my $tools_dir = "$RealBin/../../lib/CLIO/Tools";
find(
    {
        wanted => sub {
            push @tool_files, $_ if /\.pm$/ && $_ !~ m{/Tool\.pm$};
        },
        no_chdir => 1,
    },
    $tools_dir,
);

my @skip = (
    qr{/MCPBridge\.pm$},
    qr{/PluginBridge\.pm$},
    qr{/Registry\.pm$},
    qr{/Tool\.pm$},
);
@tool_files = grep {
    my $keep = 1;
    for my $re (@skip) { $keep = 0 if $_ =~ $re; }
    $keep;
} @tool_files;

print "=== Tool Schema/Implementation Drift Test ===\n\n";
print "Found ", scalar(@tool_files), " tool modules\n\n";

sub _load_source {
    my ($file) = @_;
    open my $fh, '<:encoding(UTF-8)', $file or die "Cannot read $file: $!";
    my @lines = <$fh>;
    close $fh;
    return @lines;
}

sub _param_referenced {
    my ($lines, $param) = @_;
    my $quoted = qr/['"]?\Q$param\E['"]?/;
    my $re = qr/\$params->\{$quoted\}/;
    for my $line (@$lines) {
        return 1 if $line =~ $re;
    }

    # Special case: dual-JSON parameters are added via add_dual_json_parameters
    # which generates both the bare name and `${name}_json` schema entries. The
    # implementation accesses the bare name; we accept that as covering both.
    return 1 if $param =~ /^(.+)_json$/ && _param_referenced($lines, $1);

    # Special case: if a base param is referenced via add_dual_json_parameters,
    # the ${base}_json variant is also implicitly valid.
    if ($param !~ /_json$/) {
        my $dual_re = qr/add_dual_json_parameters\(\s*['"]\Q$param\E['"]/;
        for my $line (@$lines) {
            return 1 if $line =~ $dual_re;
        }
    }

    return 0;
}

for my $file (sort @tool_files) {
    my $rel = $file;
    $rel =~ s{^.*/lib/}{lib/};
    print "--- $rel ---\n";

    my $module = $rel;
    $module =~ s{^lib/}{};
    $module =~ s{/}{::}g;
    $module =~ s{\.pm$}{};

    eval "require $module; 1" or do {
        my $err = $@;
        $err =~ s/ at .* line \d+.*//s;
        $total++;
        $fail++;
        print "  NOT ok $total - $module loads: $err\n";
        next;
    };
    $total++;
    $pass++;
    print "  ok $total - $module loads cleanly\n";

    my $instance;
    eval { $instance = $module->new(); };
    if (!$instance || $@) {
        my $err = $@ || 'returned falsy';
        $err =~ s/ at .* line \d+.*//s;
        $total++;
        $fail++;
        print "  NOT ok $total - $module->new(): $err\n";
        next;
    }

    my $schema;
    eval { $schema = $instance->get_additional_parameters(); };
    if (!$schema || ref($schema) ne 'HASH') {
        $total++;
        $fail++;
        print "  NOT ok $total - $module->get_additional_parameters returned non-hashref\n";
        next;
    }

    my @lines = _load_source($file);
    my $schema_count = scalar(keys %$schema);

    my @declared_unused;
    for my $param (sort keys %$schema) {
        push @declared_unused, $param unless _param_referenced(\@lines, $param);
    }

    if (@declared_unused) {
        my $unused = join(', ', @declared_unused);
        $total++;
        $fail++;
        print "  NOT ok $total - $schema_count params declared; ", scalar(@declared_unused), " never referenced: $unused\n";
    } else {
        $total++;
        $pass++;
        print "  ok $total - all $schema_count schema params are referenced in implementation\n";
    }
}

print "\n=== Results: $pass/$total passed";
print " ($fail FAILED)" if $fail;
print " ===\n";

exit($fail > 0 ? 1 : 0);
