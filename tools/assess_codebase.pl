#!/usr/bin/env perl

=head1 NAME

assess_codebase.pl - Automated CLIO codebase metrics collector

=head1 SYNOPSIS

    perl tools/assess_codebase.pl
    perl tools/assess_codebase.pl --json
    perl tools/assess_codebase.pl --score-only

=head1 DESCRIPTION

Collects all metrics needed for codebase assessment per the methodology
defined in tools/ASSESSMENT_METHODOLOGY.md. Outputs facts only - no
interpretation. Apply the rubric to get a score.

=cut

use strict;
use warnings;
use utf8;
use File::Find;
use File::Basename;
use Cwd 'abs_path';

my $json_mode = grep { $_ eq '--json' } @ARGV;
my $score_mode = grep { $_ eq '--score-only' } @ARGV;

# Find project root (parent of tools/)
my $script_dir = dirname(abs_path($0));
my $project_root = dirname($script_dir);
chdir $project_root or die "Cannot chdir to $project_root: $!\n";

my %metrics;

# ═══════════════════════════════════════════════════
# CATEGORY 1: Code Hygiene
# ═══════════════════════════════════════════════════

print "Collecting Code Hygiene metrics...\n" unless $json_mode;

my @pm_files;
find(sub {
    push @pm_files, $File::Find::name if /\.pm$/;
}, 'lib/CLIO');

$metrics{total_modules} = scalar @pm_files;

my ($has_strict, $has_warnings, $has_utf8, $has_pod) = (0, 0, 0, 0);
my ($has_print_stderr, $has_json_pp_direct, $has_bare_die_non_fork) = (0, 0, 0);
my ($has_croak, $has_logger) = (0, 0);

for my $file (@pm_files) {
    open my $fh, '<', $file or next;
    my $content = do { local $/; <$fh> };
    close $fh;

    $has_strict++   if $content =~ /^use strict;/m;
    $has_warnings++ if $content =~ /^use warnings;/m;
    $has_utf8++     if $content =~ /^use utf8;/m;
    $has_pod++      if $content =~ /^=head1 NAME/m;

    # Count modules with raw print STDERR (excluding Logger.pm itself)
    if ($file !~ /Logger\.pm$/ && $content =~ /print STDERR/) {
        $has_print_stderr++;
    }

    # Direct JSON::PP usage (not via CLIO::Util::JSON)
    if ($content =~ /use JSON::PP\b/ && $file !~ /Util\/JSON\.pm/) {
        $has_json_pp_direct++;
    }

    # Bare die in non-fork/signal contexts
    my @lines = split /\n/, $content;
    my $in_fork_block = 0;
    for my $i (0..$#lines) {
        $in_fork_block = 1 if $lines[$i] =~ /\bfork\b|\bSIG\{|\bsignal\b|\bexec\b|\bsetsid\b/;
        $in_fork_block = 0 if $lines[$i] =~ /^\s*\}/;
        if ($lines[$i] =~ /\bdie\b/ && $lines[$i] !~ /^\s*#/ && $lines[$i] !~ /croak|confess|=head|=cut/) {
            # Skip die inside eval (that's how you throw from eval)
            # Skip die in fork/signal contexts
            next if $in_fork_block;
            # Check if inside an eval block (rough)
            my $in_eval = 0;
            for my $j (reverse max(0, $i-20)..$i) {
                if ($lines[$j] =~ /\beval\s*\{/) { $in_eval = 1; last }
                if ($lines[$j] =~ /^\s*\};/) { last }
            }
            $has_bare_die_non_fork++ unless $in_eval;
        }
    }

    $has_croak++  if $content =~ /\bcroak\b/;
    $has_logger++ if $content =~ /use CLIO::Core::Logger/;
}

$metrics{hygiene} = {
    strict_pct      => pct($has_strict, $metrics{total_modules}),
    warnings_pct    => pct($has_warnings, $metrics{total_modules}),
    utf8_pct        => pct($has_utf8, $metrics{total_modules}),
    pod_pct         => pct($has_pod, $metrics{total_modules}),
    print_stderr    => $has_print_stderr,
    json_pp_direct  => $has_json_pp_direct,
    croak_modules   => $has_croak,
    logger_modules  => $has_logger,
};

# ═══════════════════════════════════════════════════
# CATEGORY 2: Error Handling
# ═══════════════════════════════════════════════════

print "Collecting Error Handling metrics...\n" unless $json_mode;

my ($eval_total, $eval_checked, $eval_defensive, $eval_unchecked) = (0, 0, 0, 0);
my $bare_die_count = 0;

for my $file (@pm_files) {
    open my $fh, '<', $file or next;
    my @lines = <$fh>;
    close $fh;

    for my $i (0..$#lines) {
        next unless $lines[$i] =~ /eval\s*\{/;
        $eval_total++;

        my $has_check = 0;
        my $eval_end = $i;

        # Find eval end and check for $@ handling
        for my $j ($i..$i+30) {
            last if $j > $#lines;
            if ($lines[$j] =~ /\$\@/) { $has_check = 1; last }
            if ($lines[$j] =~ /or\s+(return|next|last|die|croak)/) { $has_check = 1; last }
            if ($lines[$j] =~ /\/\/\s/ && $j > $i) { $has_check = 1; last }
            if ($lines[$j] =~ /\}\s*;/ && $j > $i) { $eval_end = $j; }
        }

        if ($has_check) {
            $eval_checked++;
        } elsif ($eval_end - $i <= 3) {
            $eval_defensive++;  # Short try-ignore
        } else {
            $eval_unchecked++;
        }
    }

    # Count bare die outside eval
    for my $i (0..$#lines) {
        next unless $lines[$i] =~ /\bdie\b/;
        next if $lines[$i] =~ /^\s*#|=head|=cut|croak|confess/;
        # Check if inside eval
        my $in_eval = 0;
        for my $j (reverse max(0, $i-20)..$i) {
            if ($lines[$j] =~ /\beval\s*\{/) { $in_eval = 1; last }
            if ($lines[$j] =~ /^\s*\}\s*;/ && $j < $i) { last }
        }
        $bare_die_count++ unless $in_eval;
    }
}

my $eval_handled_pct = $eval_total > 0
    ? sprintf("%.1f", (($eval_checked + $eval_defensive) / $eval_total) * 100)
    : 100;

$metrics{error_handling} = {
    eval_total      => $eval_total,
    eval_checked    => $eval_checked,
    eval_defensive  => $eval_defensive,
    eval_unchecked  => $eval_unchecked,
    eval_handled_pct => $eval_handled_pct,
    bare_die_outside_eval => $bare_die_count,
};

# ═══════════════════════════════════════════════════
# CATEGORY 3: Architecture
# ═══════════════════════════════════════════════════

print "Collecting Architecture metrics...\n" unless $json_mode;

my %module_lines;
my %namespaces;
my $dead_modules = 0;

for my $file (@pm_files) {
    open my $fh, '<', $file or next;
    my $line_count = 0;
    $line_count++ while <$fh>;
    close $fh;
    $module_lines{$file} = $line_count;

    # Extract namespace
    my ($ns) = $file =~ m{lib/CLIO/([^/]+)/};
    $ns //= 'Core';
    $namespaces{$ns}++;
}

my @over_1000 = grep { $module_lines{$_} > 1000 } keys %module_lines;
my @over_500  = grep { $module_lines{$_} > 500 } keys %module_lines;

# Count namespaces
my $namespace_count = scalar keys %namespaces;

# Find max fan-out (most imported module)
my %import_count;
for my $file (@pm_files) {
    open my $fh, '<', $file or next;
    while (<$fh>) {
        if (/^use (CLIO::\S+)/) {
            $import_count{$1}++;
        }
    }
    close $fh;
}
my ($max_fanout_module) = sort { $import_count{$b} <=> $import_count{$a} } keys %import_count;
my $max_fanout = $import_count{$max_fanout_module // ''} // 0;

$metrics{architecture} = {
    modules_over_1000     => scalar @over_1000,
    modules_over_1000_pct => pct(scalar @over_1000, $metrics{total_modules}),
    modules_over_500      => scalar @over_500,
    namespace_count       => $namespace_count,
    namespaces            => [sort keys %namespaces],
    max_fanout            => $max_fanout,
    max_fanout_module     => $max_fanout_module // 'none',
    top5_largest          => [map { { file => basename($_), lines => $module_lines{$_} } }
                              (sort { $module_lines{$b} <=> $module_lines{$a} } keys %module_lines)[0..4]],
};

# ═══════════════════════════════════════════════════
# CATEGORY 4: Method Quality
# ═══════════════════════════════════════════════════

print "Collecting Method Quality metrics...\n" unless $json_mode;

my @all_method_sizes;
my %module_method_counts;
my $worst_method_size = 0;
my $worst_method_name = '';
my $worst_method_file = '';

for my $file (@pm_files) {
    open my $fh, '<', $file or next;
    my @lines = <$fh>;
    close $fh;

    my @methods;
    for my $i (0..$#lines) {
        if ($lines[$i] =~ /^\s*sub\s+(\w+)/) {
            push @methods, { name => $1, start => $i };
        }
    }

    # Calculate method sizes (next sub or EOF)
    for my $j (0..$#methods) {
        my $end = ($j < $#methods) ? $methods[$j+1]{start} - 1 : $#lines;
        my $size = $end - $methods[$j]{start} + 1;
        push @all_method_sizes, $size;
        $module_method_counts{$file}++;

        if ($size > $worst_method_size) {
            $worst_method_size = $size;
            $worst_method_name = $methods[$j]{name};
            $worst_method_file = basename($file);
        }
    }
}

my @over_100 = grep { $_ > 100 } @all_method_sizes;
my @over_200 = grep { $_ > 200 } @all_method_sizes;

my $rate_over_100 = $metrics{total_modules} > 0
    ? sprintf("%.2f", scalar(@over_100) / $metrics{total_modules})
    : 0;

# Average method size in top 5 largest modules
my @top5_files = (sort { $module_lines{$b} <=> $module_lines{$a} } keys %module_lines)[0..4];
my $top5_total_methods = 0;
my $top5_total_lines = 0;
for my $f (@top5_files) {
    $top5_total_methods += ($module_method_counts{$f} // 1);
    $top5_total_lines += $module_lines{$f};
}
my $top5_avg_method = $top5_total_methods > 0
    ? sprintf("%.0f", $top5_total_lines / $top5_total_methods)
    : 0;

$metrics{methods} = {
    total_methods     => scalar @all_method_sizes,
    over_100_count    => scalar @over_100,
    over_100_rate     => $rate_over_100,
    over_200_count    => scalar @over_200,
    worst_method_size => $worst_method_size,
    worst_method_name => $worst_method_name,
    worst_method_file => $worst_method_file,
    top5_avg_method   => $top5_avg_method,
};

# ═══════════════════════════════════════════════════
# CATEGORY 5: Testing
# ═══════════════════════════════════════════════════

print "Collecting Testing metrics...\n" unless $json_mode;

# Count test files
my @unit_tests;
find(sub { push @unit_tests, $File::Find::name if /\.(?:pl|t)$/ }, 'tests/unit') if -d 'tests/unit';

my @integration_tests;
find(sub { push @integration_tests, $File::Find::name if /\.(?:pl|t)$/ }, 'tests/integration') if -d 'tests/integration';

my @e2e_tests;
find(sub { push @e2e_tests, $File::Find::name if /\.(?:pl|t)$/ }, 'tests/e2e') if -d 'tests/e2e';

# Identify infra-dependent tests (need broker/agent)
my @infra_tests;
my @standalone_integration;
for my $t (@integration_tests) {
    my $base = basename($t);
    # These tests require running broker/agent infrastructure
    if ($base =~ /subagent|multi_?agent|multiagent|broker|collaborative|autonomous|real_multi|e2e_subagent|demo_|message_ordering|session_resume|agent_interrupt|agent_loop/) {
        push @infra_tests, $t;
    } else {
        push @standalone_integration, $t;
    }
}

# Run unit tests (capture pass/fail)
my ($unit_pass, $unit_fail) = (0, 0);
for my $t (@unit_tests) {
    my $result = system("timeout 15 perl -I lib $t > /dev/null 2>&1");
    if ($result == 0) { $unit_pass++ } else { $unit_fail++ }
}

# Run standalone integration tests
my ($int_pass, $int_fail) = (0, 0);
my @int_failures;
for my $t (@standalone_integration) {
    my $result = system("timeout 15 perl -I lib $t > /dev/null 2>&1");
    if ($result == 0) { $int_pass++ } else { $int_fail++; push @int_failures, basename($t) }
}

# Check test runner
my $runner_works = (-f 'tests/run_all_tests.pl' && 
    system("timeout 10 perl tests/run_all_tests.pl --unit > /dev/null 2>&1") == 0) ? 1 : 0;

# CI workflows
my @ci_workflows = glob('.github/workflows/*.yml');

# Check if CI runs tests
my $ci_runs_tests = 0;
for my $wf (@ci_workflows) {
    open my $fh, '<', $wf or next;
    my $content = do { local $/; <$fh> };
    close $fh;
    $ci_runs_tests = 1 if $content =~ /run_all_tests|prove|perl.*test/i;
}

# Check if CI runs syntax checks
my $ci_runs_syntax = 0;
for my $wf (@ci_workflows) {
    open my $fh, '<', $wf or next;
    my $content = do { local $/; <$fh> };
    close $fh;
    $ci_runs_syntax = 1 if $content =~ /perl.*-c\b|syntax.check/i;
}

my $test_module_ratio = $metrics{total_modules} > 0
    ? sprintf("%.2f", (scalar(@unit_tests) + scalar(@standalone_integration)) / $metrics{total_modules})
    : 0;

$metrics{testing} = {
    unit_total       => scalar @unit_tests,
    unit_pass        => $unit_pass,
    unit_fail        => $unit_fail,
    unit_pass_pct    => pct($unit_pass, scalar @unit_tests),
    integration_standalone_total => scalar @standalone_integration,
    integration_pass => $int_pass,
    integration_fail => $int_fail,
    integration_pass_pct => pct($int_pass, scalar @standalone_integration),
    integration_failures => \@int_failures,
    infra_dependent_tests => scalar @infra_tests,
    e2e_tests        => scalar @e2e_tests,
    test_module_ratio => $test_module_ratio,
    runner_works     => $runner_works,
    ci_workflows     => scalar @ci_workflows,
    ci_runs_tests    => $ci_runs_tests,
    ci_runs_syntax   => $ci_runs_syntax,
};

# ═══════════════════════════════════════════════════
# CATEGORY 6: Product Completeness
# ═══════════════════════════════════════════════════

print "Collecting Product Completeness metrics...\n" unless $json_mode;

my @tools = glob('lib/CLIO/Tools/*.pm');
@tools = grep { !/Tool\.pm$|Registry\.pm$/ } @tools;  # Exclude base/registry

my @providers = glob('lib/CLIO/Providers/*.pm');
@providers = grep { !/Base\.pm$/ } @providers;
# GitHub Copilot provider is built into Core (not a separate provider module)
# Count it as a provider since it's a supported backend
my $implicit_providers = 0;
if (-f 'lib/CLIO/Core/GitHubAuth.pm') { $implicit_providers++ }  # GitHub Copilot

my @protocols = glob('lib/CLIO/Protocols/*.pm');
my @mcp_files;
find(sub { push @mcp_files, $_ if /\.pm$/ }, 'lib/CLIO/MCP') if -d 'lib/CLIO/MCP';

my @security = glob('lib/CLIO/Security/*.pm');
my @commands = glob('lib/CLIO/UI/Commands/*.pm');
# Also count subdir commands
find(sub { push @commands, $_ if /\.pm$/ && $File::Find::dir ne 'lib/CLIO/UI/Commands' }, 'lib/CLIO/UI/Commands') if -d 'lib/CLIO/UI/Commands';

my $has_dockerfile = -f 'Dockerfile' ? 1 : 0;
my $has_install_sh = -f 'install.sh' ? 1 : 0;
my @hb_files = glob('.github/workflows/*homebrew* .github/workflows/*Homebrew*');
my $has_homebrew = scalar(@hb_files) > 0 ? 1 : 0;

my @multiplexers;
find(sub { push @multiplexers, basename($_, '.pm') if /\.pm$/ }, 'lib/CLIO/UI/Multiplexer') if -d 'lib/CLIO/UI/Multiplexer';

my @session_modules = glob('lib/CLIO/Session/*.pm');
my @memory_modules = glob('lib/CLIO/Memory/*.pm');
my @coordination_modules;
find(sub { push @coordination_modules, $_ if /\.pm$/ }, 'lib/CLIO/Coordination') if -d 'lib/CLIO/Coordination';

$metrics{product} = {
    tool_count         => scalar @tools,
    provider_count     => scalar(@providers) + $implicit_providers,
    protocol_count     => scalar @protocols,
    mcp_module_count   => scalar @mcp_files,
    security_count     => scalar @security,
    command_count      => scalar @commands,
    multiplexer_count  => scalar @multiplexers,
    session_modules    => scalar @session_modules,
    memory_modules     => scalar @memory_modules,
    coordination_modules => scalar @coordination_modules,
    has_dockerfile     => $has_dockerfile,
    has_install_sh     => $has_install_sh,
    has_homebrew       => $has_homebrew,
    ci_workflow_count  => scalar @ci_workflows,
};

# ═══════════════════════════════════════════════════
# CATEGORY 7: Documentation
# ═══════════════════════════════════════════════════

print "Collecting Documentation metrics...\n" unless $json_mode;

my $readme_lines = 0;
if (-f 'README.md') {
    open my $fh, '<', 'README.md';
    $readme_lines++ while <$fh>;
    close $fh;
}

my @doc_files = glob('docs/*.md docs/**/*.md');
my ($has_synopsis, $has_method_pod, $minimal_pod) = (0, 0, 0);

for my $file (@pm_files) {
    open my $fh, '<', $file or next;
    my $content = do { local $/; <$fh> };
    close $fh;

    $has_synopsis++ if $content =~ /=head1 SYNOPSIS/;
    $has_method_pod++ if $content =~ /=head2/;

    my $head_count = () = $content =~ /=head1/g;
    $minimal_pod++ if $head_count <= 2;
}

$metrics{documentation} = {
    readme_lines       => $readme_lines,
    doc_file_count     => scalar @doc_files,
    synopsis_pct       => pct($has_synopsis, $metrics{total_modules}),
    method_pod_pct     => pct($has_method_pod, $metrics{total_modules}),
    minimal_pod_count  => $minimal_pod,
    has_contributing    => (-f 'CONTRIBUTING.md' ? 1 : 0),
    has_license         => (-f 'LICENSE' ? 1 : 0),
};

# ═══════════════════════════════════════════════════
# CATEGORY 8: Dependencies & Portability
# ═══════════════════════════════════════════════════

print "Collecting Dependency metrics...\n" unless $json_mode;

# Check for non-core module usage
my %cpan_deps;
for my $file (@pm_files) {
    open my $fh, '<', $file or next;
    while (<$fh>) {
        if (/^use (\S+)/ && $1 !~ /^(strict|warnings|utf8|CLIO|POSIX|Cwd|File|Fcntl|IO|Carp|Exporter|Scalar|List|Time|Socket|Getopt|Encode|Storable|Data|Digest|MIME|Term|Errno|Config|DirHandle|constant|base|parent|overload|Sys|IPC|Math|B|FindBin|HTTP|Test|feature|open|bytes|locale|if|lib|English|mro)/) {
            $cpan_deps{$1}++ unless $1 =~ /^5\./ || $1 =~ /;$/;
        }
    }
    close $fh;
}

$metrics{dependencies} = {
    cpan_deps      => scalar keys %cpan_deps,
    cpan_dep_list  => [sort keys %cpan_deps],
    has_dockerfile => $has_dockerfile,
};

# ═══════════════════════════════════════════════════
# SCORING
# ═══════════════════════════════════════════════════

my %scores;

# Category 1: Code Hygiene
{
    my $h = $metrics{hygiene};
    my $min_pct = min($h->{strict_pct}, $h->{warnings_pct}, $h->{utf8_pct}, $h->{pod_pct});
    my $legacy = $h->{print_stderr} + $h->{json_pp_direct};

    if    ($min_pct == 100 && $legacy == 0) { $scores{hygiene} = 10 }
    elsif ($min_pct >= 95  && $legacy < 5)  { $scores{hygiene} = 9 }
    elsif ($min_pct >= 90  && $legacy < 15) { $scores{hygiene} = 8 }
    elsif ($min_pct >= 80  && $legacy < 30) { $scores{hygiene} = 7 }
    elsif ($min_pct >= 60)                  { $scores{hygiene} = 6 }
    else                                    { $scores{hygiene} = 5 }
}

# Category 2: Error Handling
{
    my $e = $metrics{error_handling};
    my $handled_pct = $e->{eval_handled_pct};
    my $bare_die = $e->{bare_die_outside_eval};

    if    ($handled_pct >= 95 && $bare_die == 0)  { $scores{error_handling} = 10 }
    elsif ($handled_pct >= 90 && $bare_die < 5)   { $scores{error_handling} = 9 }
    elsif ($handled_pct >= 80 && $bare_die < 15)  { $scores{error_handling} = 8 }
    elsif ($handled_pct >= 70 && $bare_die < 30)  { $scores{error_handling} = 7 }
    elsif ($handled_pct >= 60)                    { $scores{error_handling} = 6 }
    else                                          { $scores{error_handling} = 5 }
}

# Category 3: Architecture
{
    my $a = $metrics{architecture};
    my $over_1000_pct = $a->{modules_over_1000_pct};
    my $ns = $a->{namespace_count};
    my $fanout = $a->{max_fanout};

    if    ($over_1000_pct == 0 && $ns > 10 && $fanout < 50)   { $scores{architecture} = 10 }
    elsif ($over_1000_pct < 3  && $ns > 8  && $fanout < 75)   { $scores{architecture} = 9 }
    elsif ($over_1000_pct < 7  && $ns > 6  && $fanout < 100)  { $scores{architecture} = 8 }
    elsif ($over_1000_pct < 10 && $ns > 5)                    { $scores{architecture} = 7 }
    elsif ($over_1000_pct < 15 && $ns > 3)                    { $scores{architecture} = 6 }
    else                                                      { $scores{architecture} = 5 }
}

# Category 4: Method Quality
{
    my $m = $metrics{methods};
    my $rate = $m->{over_100_rate};
    my $over_200 = $m->{over_200_count};
    my $worst = $m->{worst_method_size};

    if    ($over_200 == 0 && $rate < 0.3 && $worst < 150) { $scores{methods} = 10 }
    elsif ($over_200 < 3  && $rate < 0.5 && $worst < 250) { $scores{methods} = 9 }
    elsif ($over_200 < 8  && $rate < 0.7 && $worst < 400) { $scores{methods} = 8 }
    elsif ($over_200 < 15 && $rate < 1.0 && $worst < 600) { $scores{methods} = 7 }
    elsif ($over_200 < 25 && $rate < 1.5 && $worst < 1000){ $scores{methods} = 6 }
    else                                                  { $scores{methods} = 5 }
}

# Category 5: Testing
{
    my $t = $metrics{testing};
    my $unit_pct = $t->{unit_pass_pct};
    my $int_pct = $t->{integration_pass_pct};
    my $ratio = $t->{test_module_ratio};

    if    ($unit_pct >= 95 && $int_pct >= 90 && $ratio >= 0.8) { $scores{testing} = 10 }
    elsif ($unit_pct >= 95 && $int_pct >= 80 && $ratio >= 0.6) { $scores{testing} = 9 }
    elsif ($unit_pct >= 90 && $int_pct >= 70 && $ratio >= 0.5) { $scores{testing} = 8 }
    elsif ($unit_pct >= 85 && $int_pct >= 60 && $ratio >= 0.4) { $scores{testing} = 7 }
    elsif ($unit_pct >= 80 && $int_pct >= 50)                  { $scores{testing} = 6 }
    else                                                       { $scores{testing} = 5 }
}

# Category 6: Product Completeness
{
    my $p = $metrics{product};
    my $tools = $p->{tool_count};
    my $providers = $p->{provider_count};
    my $has_mcp = $p->{mcp_module_count} > 0 ? 1 : 0;
    my $has_multiagent = $p->{coordination_modules} > 0 ? 1 : 0;
    my $ci = $p->{ci_workflow_count};
    my $container = $p->{has_dockerfile};
    my $install_methods = $p->{has_install_sh} + $container + $p->{has_homebrew};

    if    ($tools > 10 && $providers > 2 && $has_mcp && $has_multiagent && $ci > 0 && $container && $install_methods >= 2) { $scores{product} = 10 }
    elsif ($tools > 8  && $providers > 2 && $ci > 0 && ($container || $install_methods >= 1)) { $scores{product} = 9 }
    elsif ($tools > 6  && $providers > 1 && $ci > 0)  { $scores{product} = 8 }
    elsif ($tools > 4  && $providers >= 1)             { $scores{product} = 7 }
    elsif ($tools > 2)                                 { $scores{product} = 6 }
    else                                               { $scores{product} = 5 }
}

# Category 7: Documentation
{
    my $d = $metrics{documentation};
    my $readme = $d->{readme_lines};
    my $docs = $d->{doc_file_count};
    my $syn = $d->{synopsis_pct};
    my $method = $d->{method_pod_pct};
    my $contrib = $d->{has_contributing};
    my $license = $d->{has_license};

    if    ($readme > 200 && $docs > 15 && $syn >= 90 && $method >= 90 && $contrib && $license) { $scores{documentation} = 10 }
    elsif ($readme > 100 && $docs > 10 && $syn >= 80 && $method >= 80) { $scores{documentation} = 9 }
    elsif ($readme > 0   && $docs > 5  && $syn >= 60)                  { $scores{documentation} = 8 }
    elsif ($readme > 0   && $docs > 3)                                 { $scores{documentation} = 7 }
    elsif ($readme > 0)                                                { $scores{documentation} = 6 }
    else                                                               { $scores{documentation} = 5 }
}

# Category 8: Dependencies
{
    my $deps = $metrics{dependencies}{cpan_deps};
    my $docker = $metrics{dependencies}{has_dockerfile};

    if    ($deps == 0 && $docker) { $scores{dependencies} = 10 }
    elsif ($deps < 3)             { $scores{dependencies} = 9 }
    elsif ($deps < 5)             { $scores{dependencies} = 8 }
    elsif ($deps < 10)            { $scores{dependencies} = 7 }
    elsif ($deps < 20)            { $scores{dependencies} = 6 }
    else                          { $scores{dependencies} = 5 }
}

# Weighted total
my %weights = (
    hygiene        => 0.10,
    error_handling => 0.10,
    architecture   => 0.20,
    methods        => 0.15,
    testing        => 0.15,
    product        => 0.15,
    documentation  => 0.10,
    dependencies   => 0.05,
);

my $weighted_total = 0;
for my $cat (keys %weights) {
    $weighted_total += $scores{$cat} * $weights{$cat};
}
$weighted_total = sprintf("%.1f", $weighted_total);

# ═══════════════════════════════════════════════════
# OUTPUT
# ═══════════════════════════════════════════════════

if ($json_mode) {
    require CLIO::Util::JSON;
    print CLIO::Util::JSON::encode_json({
        metrics => \%metrics,
        scores => \%scores,
        weighted_total => $weighted_total,
        timestamp => scalar localtime,
    });
    print "\n";
} elsif ($score_mode) {
    printf "CLIO Codebase Score: %s/10\n", $weighted_total;
    for my $cat (sort keys %scores) {
        printf "  %-20s %d/10 (weight: %d%%)\n", $cat, $scores{$cat}, $weights{$cat} * 100;
    }
} else {
    print "\n";
    print "=" x 60 . "\n";
    print " CLIO CODEBASE ASSESSMENT\n";
    print " Date: " . localtime() . "\n";
    print "=" x 60 . "\n\n";

    print "OVERALL SCORE: $weighted_total/10\n\n";

    my @cat_order = qw(hygiene error_handling architecture methods testing product documentation dependencies);
    my %cat_labels = (
        hygiene => 'Code Hygiene',
        error_handling => 'Error Handling',
        architecture => 'Architecture',
        methods => 'Method Quality',
        testing => 'Testing',
        product => 'Product Completeness',
        documentation => 'Documentation',
        dependencies => 'Dependencies',
    );

    for my $cat (@cat_order) {
        printf "  %-25s %2d/10  (weight: %2d%%)\n", $cat_labels{$cat}, $scores{$cat}, $weights{$cat} * 100;
    }

    print "\n" . "-" x 60 . "\n";
    print "RAW METRICS\n";
    print "-" x 60 . "\n\n";

    printf "Total modules: %d\n", $metrics{total_modules};
    printf "Total methods: %d\n", $metrics{methods}{total_methods};

    print "\n--- Code Hygiene ---\n";
    printf "  strict:    %s%%\n", $metrics{hygiene}{strict_pct};
    printf "  warnings:  %s%%\n", $metrics{hygiene}{warnings_pct};
    printf "  utf8:      %s%%\n", $metrics{hygiene}{utf8_pct};
    printf "  POD:       %s%%\n", $metrics{hygiene}{pod_pct};
    printf "  print STDERR leaks: %d\n", $metrics{hygiene}{print_stderr};
    printf "  JSON::PP direct:    %d\n", $metrics{hygiene}{json_pp_direct};
    printf "  Logger modules:     %d\n", $metrics{hygiene}{logger_modules};
    printf "  Croak modules:      %d\n", $metrics{hygiene}{croak_modules};

    print "\n--- Error Handling ---\n";
    printf "  eval total:     %d\n", $metrics{error_handling}{eval_total};
    printf "  eval checked:   %d\n", $metrics{error_handling}{eval_checked};
    printf "  eval defensive: %d\n", $metrics{error_handling}{eval_defensive};
    printf "  eval unchecked: %d\n", $metrics{error_handling}{eval_unchecked};
    printf "  handled %%:     %s%%\n", $metrics{error_handling}{eval_handled_pct};
    printf "  bare die:       %d\n", $metrics{error_handling}{bare_die_outside_eval};

    print "\n--- Architecture ---\n";
    printf "  Namespaces:        %d (%s)\n", $metrics{architecture}{namespace_count},
        join(', ', @{$metrics{architecture}{namespaces}});
    printf "  Modules > 1000:    %d (%s%%)\n", $metrics{architecture}{modules_over_1000},
        $metrics{architecture}{modules_over_1000_pct};
    printf "  Modules > 500:     %d\n", $metrics{architecture}{modules_over_500};
    printf "  Max fan-out:       %d (%s)\n", $metrics{architecture}{max_fanout},
        $metrics{architecture}{max_fanout_module};
    print  "  Top 5 largest:\n";
    for my $m (@{$metrics{architecture}{top5_largest}}) {
        printf "    %-30s %d lines\n", $m->{file}, $m->{lines};
    }

    print "\n--- Method Quality ---\n";
    printf "  Methods > 100 lines: %d (rate: %s per module)\n",
        $metrics{methods}{over_100_count}, $metrics{methods}{over_100_rate};
    printf "  Methods > 200 lines: %d\n", $metrics{methods}{over_200_count};
    printf "  Worst method:        %s::%s (%d lines)\n",
        $metrics{methods}{worst_method_file}, $metrics{methods}{worst_method_name},
        $metrics{methods}{worst_method_size};
    printf "  Avg method (top 5):  %d lines\n", $metrics{methods}{top5_avg_method};

    print "\n--- Testing ---\n";
    printf "  Unit tests:     %d/%d pass (%s%%)\n",
        $metrics{testing}{unit_pass}, $metrics{testing}{unit_total}, $metrics{testing}{unit_pass_pct};
    printf "  Integration:    %d/%d pass (%s%%)\n",
        $metrics{testing}{integration_pass}, $metrics{testing}{integration_standalone_total},
        $metrics{testing}{integration_pass_pct};
    printf "  Infra-dependent: %d (not counted)\n", $metrics{testing}{infra_dependent_tests};
    printf "  E2E tests:      %d\n", $metrics{testing}{e2e_tests};
    printf "  Test/module:    %s\n", $metrics{testing}{test_module_ratio};
    printf "  Runner works:   %s\n", $metrics{testing}{runner_works} ? 'yes' : 'NO';
    printf "  CI workflows:   %d\n", $metrics{testing}{ci_workflows};
    printf "  CI syntax:      %s\n", $metrics{testing}{ci_runs_syntax} ? 'yes' : 'no';
    printf "  CI tests:       %s\n", $metrics{testing}{ci_runs_tests} ? 'yes' : 'no';
    if (@{$metrics{testing}{integration_failures}}) {
        print  "  Failures:       " . join(', ', @{$metrics{testing}{integration_failures}}) . "\n";
    }

    print "\n--- Product Completeness ---\n";
    printf "  Tools:          %d\n", $metrics{product}{tool_count};
    printf "  Providers:      %d\n", $metrics{product}{provider_count};
    printf "  Protocols:      %d\n", $metrics{product}{protocol_count};
    printf "  MCP modules:    %d\n", $metrics{product}{mcp_module_count};
    printf "  Security:       %d\n", $metrics{product}{security_count};
    printf "  Commands:       %d\n", $metrics{product}{command_count};
    printf "  Multiplexers:   %d\n", $metrics{product}{multiplexer_count};
    printf "  Session mgmt:   %d modules\n", $metrics{product}{session_modules};
    printf "  Memory/LTM:     %d modules\n", $metrics{product}{memory_modules};
    printf "  Coordination:   %d modules\n", $metrics{product}{coordination_modules};
    printf "  Dockerfile:     %s\n", $metrics{product}{has_dockerfile} ? 'yes' : 'no';
    printf "  install.sh:     %s\n", $metrics{product}{has_install_sh} ? 'yes' : 'no';
    printf "  Homebrew:       %s\n", $metrics{product}{has_homebrew} ? 'yes' : 'no';

    print "\n--- Documentation ---\n";
    printf "  README:         %d lines\n", $metrics{documentation}{readme_lines};
    printf "  Doc files:      %d\n", $metrics{documentation}{doc_file_count};
    printf "  SYNOPSIS:       %s%%\n", $metrics{documentation}{synopsis_pct};
    printf "  Method POD:     %s%%\n", $metrics{documentation}{method_pod_pct};
    printf "  Minimal POD:    %d modules\n", $metrics{documentation}{minimal_pod_count};
    printf "  CONTRIBUTING:   %s\n", $metrics{documentation}{has_contributing} ? 'yes' : 'no';
    printf "  LICENSE:        %s\n", $metrics{documentation}{has_license} ? 'yes' : 'no';

    print "\n--- Dependencies ---\n";
    printf "  CPAN deps:      %d\n", $metrics{dependencies}{cpan_deps};
    if ($metrics{dependencies}{cpan_deps} > 0) {
        printf "  Deps:           %s\n", join(', ', @{$metrics{dependencies}{cpan_dep_list}});
    }
}

# ═══════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════

sub pct {
    my ($n, $total) = @_;
    return 100 if $total == 0;
    return sprintf("%.1f", ($n / $total) * 100);
}

sub max {
    my ($a, $b) = @_;
    return $a > $b ? $a : $b;
}

sub min {
    my @vals = @_;
    my $min = $vals[0];
    for (@vals[1..$#vals]) { $min = $_ if $_ < $min }
    return $min;
}
