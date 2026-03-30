#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;

use lib '../../lib';

# Test 1: Module loads
use_ok('CLIO::UI::PaginationManager');

# Create minimal mock UI
my $mock_ui = bless {
    terminal_height => 24,
    terminal_width => 80,
    _tools_invoked_this_request => 0,
}, 'MockUI';

# Mock methods needed by PaginationManager
{
    no strict 'refs';
    *MockUI::refresh_terminal_size = sub { };
    *MockUI::colorize = sub { return $_[1] };
    *MockUI::display_system_message = sub { };
    *MockUI::redraw_page = sub { };
}

# Test 2: Constructor
my $pager = CLIO::UI::PaginationManager->new(ui => $mock_ui);
ok($pager, 'PaginationManager created');
isa_ok($pager, 'CLIO::UI::PaginationManager');

# Test 3: Constructor requires ui
eval { CLIO::UI::PaginationManager->new() };
like($@, qr/ui.*required/i, 'constructor dies without ui');

# Test 4: Initial state
is($pager->line_count(), 0, 'initial line_count is 0');
is($pager->enabled(), 0, 'initially disabled');

# Test 5: Enable/disable
$pager->enable();
is($pager->enabled(), 1, 'enabled after enable()');
is($pager->line_count(), 0, 'line_count reset by enable()');

$pager->disable();
is($pager->enabled(), 0, 'disabled after disable()');

# Test 6: Line count manipulation
$pager->enable();
$pager->increment_lines(5);
is($pager->line_count(), 5, 'line_count after increment(5)');

$pager->increment_lines();
is($pager->line_count(), 6, 'line_count after increment() default 1');

$pager->line_count(10);
is($pager->line_count(), 10, 'line_count after set(10)');

# Test 7: Track line
$pager->reset();
$pager->enable();
$pager->track_line("hello");
$pager->track_line("world");
is($pager->line_count(), 2, 'track_line increments count');
is(scalar @{$pager->{current_page}}, 2, 'track_line pushes to current_page');

# Test 8: Threshold
is($pager->threshold(), 22, 'threshold is terminal_height - 2');

$mock_ui->{terminal_height} = 40;
is($pager->threshold(), 38, 'threshold updates with terminal_height');

$mock_ui->{terminal_height} = 24;  # restore

# Test 9: should_trigger
$pager->reset();
is($pager->should_trigger(), 0, 'no trigger when disabled');

$pager->enable();
$pager->line_count(10);
is($pager->should_trigger(), 0, 'no trigger below threshold');

$pager->line_count(22);
# Note: -t STDIN will be false in test, so should_trigger returns 0
# We test the logic by checking enabled + count

# Test 10: save_page / reset_page
$pager->reset();
$pager->enable();
$pager->track_line("line1");
$pager->track_line("line2");
$pager->save_page();
is(scalar @{$pager->{pages}}, 1, 'save_page adds to pages');
is($pager->{page_index}, 0, 'page_index set after save_page');

$pager->reset_page();
is($pager->line_count(), 0, 'line_count reset after reset_page');
is(scalar @{$pager->{current_page}}, 0, 'current_page cleared after reset_page');
is(scalar @{$pager->{pages}}, 1, 'pages preserved after reset_page');

# Test 11: Full reset
$pager->reset();
is($pager->line_count(), 0, 'line_count after full reset');
is($pager->enabled(), 0, 'disabled after full reset');
is(scalar @{$pager->{pages}}, 0, 'pages cleared after full reset');
is(scalar @{$pager->{current_page}}, 0, 'current_page cleared after full reset');

# Test 12: should_trigger with tools flag
$pager->enable();
$pager->line_count(22);
$mock_ui->{_tools_invoked_this_request} = 1;

# Without streaming flag, tools block trigger
# (can't test -t STDIN in unit test, but verify logic path)

# With streaming flag, tools don't block
# $pager->should_trigger(streaming => 1) would trigger if -t STDIN

$mock_ui->{_tools_invoked_this_request} = 0;

done_testing();
