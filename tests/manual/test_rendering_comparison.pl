#!/usr/bin/env perl

# Performance Test: Compare line-by-line vs batched markdown rendering
# This simulates the streaming render loop

use strict;
use warnings;
use lib 'lib';
use Time::HiRes qw(time);

use CLIO::UI::Markdown;
use CLIO::UI::Theme;
use CLIO::UI::ANSI;

# Create renderer
my $ansi = CLIO::UI::ANSI->new();
my $theme_mgr = CLIO::UI::Theme->new(
    ansi => $ansi,
    style => 'default',
    theme => 'default'
);
my $md = CLIO::UI::Markdown->new(theme_mgr => $theme_mgr);

# Create test content (100 lines, mixed markdown)
my @test_lines;
for my $i (1..20) {
    push @test_lines, "## Section $i\n";
    push @test_lines, "This is **bold** and *italic* text with `code`.\n";
    push @test_lines, "- Item 1\n";
    push @test_lines, "- Item 2\n";
    push @test_lines, "\n";
}

my $full_text = join('', @test_lines);
my $line_count = scalar(@test_lines);

print "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
print "MARKDOWN RENDERING PERFORMANCE COMPARISON\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";

print "Test content: $line_count lines\n\n";

# Test 1: Line-by-line rendering (OLD METHOD)
print "Test 1: LINE-BY-LINE rendering (old method)\n";
my $iterations = 50;
my $start = time();

for (1..$iterations) {
    for my $line (@test_lines) {
        next unless $line =~ /\S/;  # Skip blank lines
        my $rendered = $md->render($line);
        my $parsed = $ansi->parse($rendered);
        # Simulating print: length($parsed);
    }
}

my $end = time();
my $line_by_line_time = $end - $start;
my $line_by_line_avg = ($line_by_line_time / $iterations) * 1000;

print "  Total time: " . sprintf("%.3f", $line_by_line_time) . "s\n";
print "  Avg per iteration: " . sprintf("%.2f", $line_by_line_avg) . "ms\n";
print "  Render calls: " . ($line_count * $iterations) . "\n\n";

# Test 2: Batched rendering (NEW METHOD)
print "Test 2: BATCHED rendering (new method, batch size 10)\n";
$start = time();

for (1..$iterations) {
    my $buffer = '';
    my $count = 0;
    
    for my $line (@test_lines) {
        $buffer .= $line;
        $count++;
        
        if ($count >= 10) {
            my $rendered = $md->render($buffer);
            my $parsed = $ansi->parse($rendered);
            # Simulating print: length($parsed);
            $buffer = '';
            $count = 0;
        }
    }
    
    # Flush remaining
    if ($buffer) {
        my $rendered = $md->render($buffer);
        my $parsed = $ansi->parse($rendered);
    }
}

$end = time();
my $batched_time = $end - $start;
my $batched_avg = ($batched_time / $iterations) * 1000;

print "  Total time: " . sprintf("%.3f", $batched_time) . "s\n";
print "  Avg per iteration: " . sprintf("%.2f", $batched_avg) . "ms\n";
print "  Render calls: ~" . (($line_count / 10) * $iterations) . "\n\n";

# Results
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
print "RESULTS\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";

my $improvement = (($line_by_line_time - $batched_time) / $line_by_line_time) * 100;
my $speedup = $line_by_line_time / $batched_time;

print "Batched rendering is:\n";
print "  " . sprintf("%.1f", $improvement) . "% faster\n";
print "  " . sprintf("%.2f", $speedup) . "x speedup\n";
print "  Reduced render() calls by " . sprintf("%.0f", 100 - (100/$line_count)*10) . "%\n\n";

if ($improvement > 50) {
    print "✓ SIGNIFICANT IMPROVEMENT - Smart buffering works!\n";
} elsif ($improvement > 20) {
    print "✓ GOOD IMPROVEMENT - Noticeable performance gain\n";
} elsif ($improvement > 0) {
    print "⚠ MINOR IMPROVEMENT - Some benefit but not dramatic\n";
} else {
    print "✗ NO IMPROVEMENT - Batching didn't help\n";
}

print "\n";
