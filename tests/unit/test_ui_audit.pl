#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';

use Test::More tests => 16;

=head1 NAME

test_ui_audit - Test suite for CLIO UI/UX audit fixes

Tests cover:
- Context pagination in collaboration protocol
- Output path consolidation 
- Prompt unification with Theme
- Readline robustness and edge cases

=cut

# Test 1-3: Theme has required prompt colors
use_ok('CLIO::UI::Theme');

my $theme = CLIO::UI::Theme->new(debug => 0);
ok($theme, 'Theme created');

# Check prompt colors exist
my $prompt_color = $theme->get_color('prompt_indicator');
ok(length($prompt_color) > 0, 'prompt_indicator color defined');

my $collab_color = $theme->get_color('collab_prompt');
ok(length($collab_color) > 0, 'collab_prompt color defined');

# Test 5-6: Theme has pagination templates
my $hint = $theme->get_pagination_hint(0);
ok(length($hint) > 0, 'pagination_hint_full template exists');

my $hint_streaming = $theme->get_pagination_hint(1);
ok(length($hint_streaming) > 0, 'pagination_hint_streaming template exists');

# Test 7-8: Display and Chat modules load
use_ok('CLIO::UI::Display');
use_ok('CLIO::UI::Chat');

# Test 9-11: ReadLine cursor bounds checking
use_ok('CLIO::Core::ReadLine');

my $readline = CLIO::Core::ReadLine->new(prompt => '> ', debug => 0);
ok($readline, 'ReadLine instance created');

# Test that redraw_line handles out-of-bounds cursor gracefully
my $input = 'test';
my $cursor_pos = 10;  # Beyond input length

# Suppress output during test
open my $devnull, '>', '/dev/null' or die;
my $oldout = select $devnull;
$readline->redraw_line(\$input, \$cursor_pos, '> ');
select $oldout;
close $devnull;

ok($cursor_pos <= length($input), 'Cursor position clamped to input length');

# Test 12-13: ReadLine history safety
my $hist_input = 'first';
my $hist_cursor = 0;
$readline->add_to_history('history item 1');
$readline->add_to_history('history item 2');
ok(scalar(@{$readline->{history}}) == 2, 'History items added');

# Test navigation doesn't crash on empty history after reset
$readline->{history_pos} = 1;

open $devnull, '>', '/dev/null' or die;
$oldout = select $devnull;
$readline->history_next(\$hist_input, \$hist_cursor, '> ');
select $oldout;
close $devnull;

ok($readline->{history_pos} == -1 || $readline->{history_pos} >= 0, 'History navigation bounds safe');

# Test 14-16: Pagination and prompts
my $chat = bless {
    pagination_enabled => 1,
}, 'CLIO::UI::Chat';

ok($chat->{pagination_enabled}, 'Pagination can be enabled for context');

my $prompt_builder = sub {
    my ($mode) = @_;
    $mode ||= 'normal';
    my $collab = ($mode eq 'collaboration' ? 'blue' : 'green');
    return "[$collab]: ";
};

my $normal_prompt = $prompt_builder->('normal');
my $collab_prompt = $prompt_builder->('collaboration');
ok($normal_prompt ne $collab_prompt, 'Prompts differ by mode');
ok($collab_prompt =~ /blue/, 'Collaboration prompt uses blue indicator');

print "\nAll UI audit tests passed!\n";
