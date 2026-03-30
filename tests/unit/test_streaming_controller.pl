#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;

use lib '../../lib';

# Test 1: Module loads
use_ok('CLIO::UI::StreamingController');

# Create a minimal mock pager
my $mock_pager = bless {
    line_count => 0,
    pages => [],
    current_page => [],
    page_index => 0,
    pagination_enabled => 0,
}, 'MockPager';

# Mock pager methods
{
    no strict 'refs';
    *MockPager::enable = sub { $_[0]->{pagination_enabled} = 1 };
    *MockPager::disable = sub { $_[0]->{pagination_enabled} = 0 };
    *MockPager::reset = sub { $_[0]->{line_count} = 0; $_[0]->{pages} = []; $_[0]->{current_page} = []; $_[0]->{page_index} = 0; $_[0]->{pagination_enabled} = 0 };
    *MockPager::reset_page = sub { $_[0]->{line_count} = 0; $_[0]->{current_page} = [] };
    *MockPager::track_line = sub { push @{$_[0]->{current_page}}, $_[1]; $_[0]->{line_count}++ };
    *MockPager::increment_lines = sub { $_[0]->{line_count} += ($_[1] // 1) };
    *MockPager::line_count = sub { $_[0]->{line_count} = $_[1] if defined $_[1]; $_[0]->{line_count} };
    *MockPager::enabled = sub { $_[0]->{pagination_enabled} };
}

# Create a minimal mock chat object
my $mock_chat = bless {
    enable_markdown => 0,
    debug => 0,
    stop_streaming => 0,
    _last_was_system_message => 0,
    _prepare_for_next_iteration => 0,
    pager => $mock_pager,
}, 'MockChat';

# Test 2: Constructor
my $sc = CLIO::UI::StreamingController->new(ui => $mock_chat);
ok($sc, 'StreamingController created');
isa_ok($sc, 'CLIO::UI::StreamingController');

# Test 3: Constructor requires ui
eval { CLIO::UI::StreamingController->new() };
like($@, qr/ui.*required/i, 'constructor dies without ui');

# Test 4: Initial state
is($sc->content(), '', 'initial content is empty');
ok(!$sc->first_chunk_received(), 'first_chunk_received is false initially');

# Test 5: Reset clears state
$sc->{accumulated_content} = 'test content';
$sc->{first_chunk_received} = 1;
$sc->{markdown_buffer} = 'buffered';
$sc->{line_buffer} = 'lines';
$sc->{in_code_block} = 1;
$sc->{in_table} = 1;
$sc->reset();
is($sc->content(), '', 'content cleared after reset');
ok(!$sc->first_chunk_received(), 'first_chunk_received cleared after reset');
is($sc->{markdown_buffer}, '', 'markdown_buffer cleared after reset');
is($sc->{line_buffer}, '', 'line_buffer cleared after reset');
is($sc->{in_code_block}, 0, 'in_code_block cleared after reset');
is($sc->{in_table}, 0, 'in_table cleared after reset');
is($sc->{md_line_count}, 0, 'md_line_count cleared after reset');

# Test 6: Session marker stripping via flush
{
    $sc->reset();
    $sc->{markdown_buffer} = "Hello world <!--session:{\"name\":\"test\"}-->";
    my $output = '';
    open my $capture, '>', \$output;
    my $old_stdout = select $capture;
    $sc->flush();
    select $old_stdout;
    close $capture;
    unlike($output, qr/<!--session/, 'session markers stripped during flush');
    like($output, qr/Hello world/, 'content preserved after marker strip');
}

# Test 7: Content accumulation via accessor
$sc->reset();
$sc->{accumulated_content} = 'Hello ';
$sc->{accumulated_content} .= 'World';
is($sc->content(), 'Hello World', 'content accumulates correctly');

# Test 8: Flush with empty buffers (should not crash)
$sc->reset();
$sc->flush();
is($sc->content(), '', 'flush with empty buffers is safe');

# Test 9: Flush with markdown buffer content
{
    $sc->reset();
    $sc->{markdown_buffer} = "Some bold text";
    my $output = '';
    open my $capture, '>', \$output;
    my $old_stdout = select $capture;
    $sc->flush();
    select $old_stdout;
    close $capture;
    like($output, qr/Some bold text/, 'markdown buffer flushed to output');
    is($sc->{markdown_buffer}, '', 'markdown buffer cleared after flush');
}

# Test 10: Flush with line buffer content
{
    $sc->reset();
    $sc->{line_buffer} = "Incomplete line";
    my $output = '';
    open my $capture, '>', \$output;
    my $old_stdout = select $capture;
    $sc->flush();
    select $old_stdout;
    close $capture;
    like($output, qr/Incomplete line/, 'line buffer flushed to output');
    is($sc->{line_buffer}, '', 'line buffer cleared after flush');
}

# Test 11: Whitespace-only buffers not flushed
{
    $sc->reset();
    $sc->{markdown_buffer} = "   \n  ";
    $sc->{line_buffer} = "  \t  ";
    my $output = '';
    open my $capture, '>', \$output;
    my $old_stdout = select $capture;
    $sc->flush();
    select $old_stdout;
    close $capture;
    is($output, '', 'whitespace-only buffers not flushed');
}

# Test 12: make_on_chunk_callback returns a coderef
{
    my $mock_spinner = bless {}, 'MockSpinner';
    my $mock_host = bless {}, 'MockHostProto';
    my $callback = $sc->make_on_chunk_callback(
        spinner    => $mock_spinner,
        host_proto => $mock_host,
    );
    is(ref($callback), 'CODE', 'make_on_chunk_callback returns a coderef');
}

# Test 13: make_on_chunk_callback requires spinner
eval { $sc->make_on_chunk_callback(host_proto => bless({}, 'MockHostProto')) };
like($@, qr/spinner required/, 'dies without spinner');

# Test 14: make_on_chunk_callback requires host_proto
eval { $sc->make_on_chunk_callback(spinner => bless({}, 'MockSpinner')) };
like($@, qr/host_proto required/, 'dies without host_proto');

# Test 15: Callback processes content chunks
{
    $sc->reset();
    my $mock_spinner = bless {}, 'MockSpinner';
    my $mock_host = bless {}, 'MockHostProto';

    my $cb = $sc->make_on_chunk_callback(
        spinner    => $mock_spinner,
        host_proto => $mock_host,
    );

    # Capture output
    my $output = '';
    open my $capture, '>', \$output;
    my $old_stdout = select $capture;

    $cb->("Hello World\n");
    ok($sc->first_chunk_received(), 'first_chunk_received set after chunk');
    like($sc->content(), qr/Hello World/, 'content accumulated from chunk');

    # Second chunk should not re-trigger first-chunk logic
    $cb->("Second line\n");
    like($sc->content(), qr/Second line/, 'second chunk accumulated');

    select $old_stdout;
    close $capture;
}

# Test 16: flush_for_tools clears visual state
{
    $sc->reset();
    $sc->{markdown_buffer} = "In-progress content";
    $sc->{line_buffer} = "partial";
    $sc->{in_code_block} = 1;

    my $output = '';
    open my $capture, '>', \$output;
    my $old_stdout = select $capture;
    $sc->flush_for_tools();
    select $old_stdout;
    close $capture;

    is($sc->{markdown_buffer}, '', 'markdown_buffer cleared by flush_for_tools');
    is($sc->{line_buffer}, '', 'line_buffer cleared by flush_for_tools');
    # in_code_block is NOT cleared by flush_for_tools (streaming context preserved)
    is($sc->{in_code_block}, 1, 'in_code_block preserved by flush_for_tools');
    # accumulated_content should be preserved
    # (flush_for_tools resets display state, not content tracking)
}

# Test 17: stop_streaming flag prevents processing
{
    $sc->reset();
    $mock_chat->{stop_streaming} = 1;

    my $mock_spinner = bless {}, 'MockSpinner';
    my $mock_host = bless {}, 'MockHostProto';
    my $cb = $sc->make_on_chunk_callback(
        spinner    => $mock_spinner,
        host_proto => $mock_host,
    );

    my $output = '';
    open my $capture, '>', \$output;
    my $old_stdout = select $capture;
    $cb->("Should be ignored\n");
    select $old_stdout;
    close $capture;

    ok(!$sc->first_chunk_received(), 'chunk ignored when stop_streaming set');
    is($sc->content(), '', 'no content when stop_streaming set');

    $mock_chat->{stop_streaming} = 0;  # restore
}

done_testing();

# ---- Mock classes ----

package MockChat;

sub render_markdown { return $_[1] }
sub colorize { return $_[1] }  # just return text
sub pause { }

1;

package MockSpinner;
sub stop { }
1;

package MockHostProto;
sub emit { }
sub emit_status { }
1;
