#!/usr/bin/env perl
# Test: PaginationManager state machine and basic operations
# Covers:
#   - reset clears all state
#   - track_line + save_page correctly manages pages
#   - line count and should_trigger at threshold
#   - enable/disable toggles
#   - threshold calculation

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use lib '../../lib';

BEGIN {
    no warnings 'redefine';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (80, 24); };
}

use CLIO::UI::Chat;
use CLIO::UI::PaginationManager;

my ($pass, $fail) = (0, 0);

sub ok_int {
    my ($got, $expected, $label) = @_;
    if (defined $got && $got == $expected) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (got=" . (defined $got ? $got : 'undef') . ", expected=$expected)\n";
        $fail++;
    }
}

sub ok_str {
    my ($got, $expected, $label) = @_;
    if (defined $got && $got eq $expected) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (got='$got', expected='$expected')\n";
        $fail++;
    }
}

my $chat = CLIO::UI::Chat->new(debug => 0, config => undef, session => undef, no_color => 1);
my $pager = CLIO::UI::PaginationManager->new(ui => $chat);
# Force is_terminal for test environment (STDIN may be a pipe in test harness).
$pager->{is_terminal} = 1;

# --- Reset state ---
{
    $pager->{line_count} = 50;
    $pager->{current_page} = ['x'];

    $pager->reset();
    ok_int($pager->{line_count}, 0, 'reset clears line_count');
    ok_int(scalar(@{$pager->{current_page}}), 0, 'reset clears current_page');
    ok_int(scalar(@{$pager->{pages}}), 0, 'reset clears pages');
    ok_int($pager->{page_index}, 0, 'reset clears page_index');
    ok_int($pager->{pagination_enabled}, 0, 'reset disables pagination');
}

# --- enable/disable ---
{
    $pager->reset();
    ok_int($pager->enabled(), 0, 'pagination starts disabled');

    $pager->enable();
    ok_int($pager->enabled(), 1, 'enable sets enabled=1');

    $pager->disable();
    ok_int($pager->enabled(), 0, 'disable sets enabled=0');
}

# --- Line counting ---
{
    $pager->reset();
    $pager->increment_lines(3);
    ok_int($pager->line_count(), 3, 'increment_lines adds 3');
    $pager->increment_lines(2);
    ok_int($pager->line_count(), 5, 'increment_lines accumulates to 5');
    $pager->increment_lines(0);
    ok_int($pager->line_count(), 5, 'increment_lines(0) is a no-op');
}

# --- track_line adds to current_page AND increments line_count ---
{
    $pager->reset();
    $pager->track_line("line 1");
    ok_int(scalar(@{$pager->{current_page}}), 1, 'track_line populates current_page');
    ok_str($pager->{current_page}->[0], 'line 1', 'track_line stores content in current_page');
    ok_int($pager->line_count(), 1, 'track_line increments line_count');
    # track_line returns the pre-increment value
    $pager->{line_count} = 10;
    my $ret = $pager->track_line("line 2");
    ok_int($ret // 0, 10, 'track_line returns pre-increment count');
    ok_int($pager->line_count(), 11, 'line_count incremented to 11');
}

# --- threshold is terminal_height - 2 ---
{
    ok_int($pager->threshold(), 22, 'threshold is terminal_height-2 (24-2=22)');
}

# --- should_trigger with is_terminal=1 ---
{
    $pager->reset();
    $pager->enable();
    ok_int($pager->should_trigger(), 0, 'should_trigger false at 0 lines');
    $pager->increment_lines(21);
    ok_int($pager->should_trigger(), 0, 'should_trigger false at 21 lines (below threshold)');
    $pager->increment_lines(1);
    ok_int($pager->should_trigger(), 1, 'should_trigger true at 22 lines (threshold)');
    $pager->increment_lines(10);
    ok_int($pager->should_trigger(), 1, 'should_trigger true beyond threshold');
}

# --- should_trigger respects disable ---
{
    $pager->reset();
    $pager->disable();
    $pager->increment_lines(100);
    ok_int($pager->should_trigger(), 0, 'should_trigger false when disabled');
}

# --- save_page clones current_page into pages array ---
{
    $pager->reset();
    $pager->track_line("a");
    $pager->track_line("b");
    $pager->save_page();
    ok_int(scalar(@{$pager->{pages}}), 1, 'one page saved');
    ok_str(join(',', @{$pager->{pages}->[0]}), 'a,b', 'saved page contains tracked lines');

    # Second page
    $pager->track_line("c");
    $pager->save_page();
    ok_int(scalar(@{$pager->{pages}}), 2, 'two pages saved');
    ok_str(join(',', @{$pager->{pages}->[1]}), 'a,b,c', 'second page includes previous lines');
}

# --- reset_page clears current_page without touching pages array ---
{
    $pager->{current_page} = ['x', 'y'];
    $pager->{pages} = [['old']];
    $pager->reset_page();
    ok_int(scalar(@{$pager->{current_page}}), 0, 'reset_page clears current_page');
    ok_int(scalar(@{$pager->{pages}}), 1, 'reset_page does not touch pages array');
    ok_int($pager->line_count(), 0, 'reset_page clears line_count');
}

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);