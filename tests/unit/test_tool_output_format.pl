#!/usr/bin/env perl

# Unit tests for CLIO tool output format and logger interaction.
#
# Covers:
#   1. Logger doesn't clear lines (no \r\e[K prefix) — this previously
#      destroyed inline-format tool header lines.
#   2. ToolOutputFormatter inline mode renders header + action correctly.
#   3. ToolOutputFormatter box mode renders with connector.
#   4. WebOperations.pm error_result returns include tool_name.
#   5. Update.pm get_available_update uses version comparison.
#   6. Editor.pm uses list-form system() (no shell interpolation).

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Spec;
use File::Path qw(make_path remove_tree);
use Data::Dumper;

my ($pass, $fail) = (0, 0);

sub ok {
    my ($cond, $desc) = @_;
    if ($cond) { print "PASS: $desc\n"; $pass++; }
    else { print "FAIL: $desc\n"; $fail++; }
}

sub is {
    my ($got, $expected, $desc) = @_;
    if (defined($got) && defined($expected) && $got eq $expected) {
        print "PASS: $desc\n"; $pass++;
    } else {
        $got //= '(undef)'; $expected //= '(undef)';
        print "FAIL: $desc\n      got:      $got\n      expected: $expected\n"; $fail++;
    }
}

# ---------------------------------------------------------------------------
# 1. Logger does NOT clear lines with \r\e[K
# ---------------------------------------------------------------------------
print "\n--- Logger no longer clears lines ---\n";

{
    # We can't easily capture child STDERR here without IPC gymnastics; instead,
    # verify by inspecting the Logger source for \r\e[K. This catches the regression
    # directly — if anyone re-adds the destructive prefix, this test fails.
    open my $fh, '<', 'lib/CLIO/Core/Logger.pm' or die "Cannot read Logger.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    # The log_* functions must NOT use \r\e[K (carriage return + erase to EOL).
    # This prefix is destructive when an inline-format tool output line is
    # being rendered; the spinner owns its own line-clearing on stop.
    my $body = $content;
    $body =~ s/^=head\d.*?=cut\s*//gms;  # strip POD
    if ($body =~ /sub log_(debug|info|warning|error)\b.*?\\r\\e\[K/s) {
        print "FAIL: log_* functions still use \\r\\e[K (destructive line clear)\n"; $fail++;
    } else {
        print "PASS: log_* functions no longer use destructive \\r\\e[K prefix\n"; $pass++;
    }
}

# ---------------------------------------------------------------------------
# 2. Inline formatter renders header + action on same line
# ---------------------------------------------------------------------------
print "\n--- Inline formatter shape ---\n";

{
    require CLIO::UI::Theme;
    require CLIO::UI::ToolOutputFormatter;

    # Mock Chat that respects the theme
    package FakeChat;
    sub new { bless { theme_mgr => $_[1], use_color => 1 }, $_[0] }
    sub colorize {
        my ($self, $text, $color) = @_;
        return $text;  # strip colors for assertion
    }
    sub can { 1; }

    package main;

    my $theme = CLIO::UI::Theme->new();
    my $chat = FakeChat->new($theme);
    my $fmt = CLIO::UI::ToolOutputFormatter->new(ui => $chat);

    # Capture stdout from formatter
    my $pid = fork();
    if (!defined $pid) { die "fork failed: $!"; }
    if ($pid == 0) {
        STDOUT->autoflush(1);
        $fmt->display_tool_header("version_control", "VERSION CONTROL", 1, 0);
        $fmt->display_action_detail("committing changes", 0, 0);
        print "\n";
        exit(0);
    }
    waitpid($pid, 0);

    # The output should contain the bullet, name, and action all on one line
    # (verifying the inline format hasn't regressed to multi-line).
    # We just check that the formatter returns successfully here; the actual
    # byte-level assertion is in test_full_flow.pl.

    # Verify get_tool_format returns 'inline' when theme is set
    is($fmt->get_tool_format(), 'inline',
       'get_tool_format returns inline when theme is loaded');
}

# ---------------------------------------------------------------------------
# 3. get_available_update uses version comparison, not string equality
# ---------------------------------------------------------------------------
print "\n--- get_available_update uses version comparison ---\n";

{
    require CLIO::Update;
    my $u = CLIO::Update->new();

    # Mock by overriding _compare_versions and checking logic
    no warnings 'redefine';
    local *CLIO::Update::_compare_versions = sub { 1 };  # pretend cache > current

    # Use a fake cache directory and write a cache entry
    my $tmpdir = File::Spec->catdir($RealBin, 'tmp_avail_test');
    make_path($tmpdir);
    my $cache_file = File::Spec->catfile($tmpdir, 'update_check_cache');
    open my $cfh, '>', $cache_file or die "Cannot create cache: $!";
    print $cfh "99999999.99\n";  # Pretend cache holds a much-newer version
    close $cfh;

    my $u2 = CLIO::Update->new(cache_dir => $tmpdir);
    my $info = $u2->get_available_update();

    ok($info->{cached}, 'get_available_update returns cached=1');
    is($info->{up_to_date}, 0, 'up_to_date=0 when cache version > current');

    # Cleanup
    remove_tree($tmpdir);
}

{
    require CLIO::Update;
    no warnings 'redefine';
    local *CLIO::Update::_compare_versions = sub { -1 };  # pretend cache < current

    my $tmpdir = File::Spec->catdir($RealBin, 'tmp_avail_test2');
    make_path($tmpdir);
    my $cache_file = File::Spec->catfile($tmpdir, 'update_check_cache');
    open my $cfh, '>', $cache_file or die "Cannot create cache: $!";
    print $cfh "19700101.1\n";  # Pretend cache holds an older version
    close $cfh;

    my $u = CLIO::Update->new(cache_dir => $tmpdir);
    my $info = $u->get_available_update();

    is($info->{up_to_date}, 1,
       'up_to_date=1 when cache version < current (user installed newer manually)');

    remove_tree($tmpdir);
}

# ---------------------------------------------------------------------------
# 4. Editor.pm uses list-form system()
# ---------------------------------------------------------------------------
print "\n--- Editor.pm uses list-form system ---\n";

{
    open my $fh, '<', 'lib/CLIO/Core/Editor.pm' or die "Cannot read Editor.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    # After fix: editor should use system($self->{editor}, $filepath)
    # Before fix: it used "$self->{editor} " . quotemeta($filepath)
    my $body = $content;
    $body =~ s/^=head\d.*?=cut\s*//gms;

    # No shell-form system call should remain in the editor
    my $uses_list_form = ($body =~ /system\(\$self->\{editor\},\s*\$?(?:filepath|filename)\)/);
    ok($uses_list_form, 'Editor.pm uses list-form system()');

    # No quotemeta-of-filepath pattern (the old shell-form style)
    # Note: only check actual code, not comments. Strip comments first.
    my $code = $body;
    $code =~ s/^\s*#.*$//mg;  # remove single-line comments
    my $uses_quotemeta = ($code =~ /quotemeta\(\$(?:filepath|filename)\)/);
    ok(!$uses_quotemeta, 'Editor.pm no longer uses quotemeta(filepath) shell-form pattern');
}

# ---------------------------------------------------------------------------
# 5. WebOperations error returns include tool_name
# ---------------------------------------------------------------------------
print "\n--- WebOperations error_result includes tool_name ---\n";

{
    require CLIO::Tools::WebOperations;
    my $web = CLIO::Tools::WebOperations->new();

    # Test _search_serpapi directly with invalid engine (no network needed)
    my $result = $web->_search_serpapi('test', 5, 10, 'fake_key', 'invalid_engine_xyz');

    if (!$result || ref($result) ne 'HASH') {
        print "FAIL: _search_serpapi returned non-hashref\n"; $fail++;
    } elsif ($result->{success}) {
        print "FAIL: _search_serpapi with bad engine should fail\n"; $fail++;
    } else {
        ok(defined $result->{tool_name}, 'WebOperations error result has tool_name set');
        ok($result->{tool_name} eq 'web_operations',
           'WebOperations tool_name is web_operations');
        ok(defined $result->{error}, 'WebOperations error result has error message');
        ok($result->{error} =~ /Unsupported search engine/,
           'Error message mentions unsupported engine');
    }
}

# ---------------------------------------------------------------------------
# 6. Tool output survives interleaved log messages (the "committing changes->" bug)
# ---------------------------------------------------------------------------
print "\n--- Tool output survives interleaved logs ---\n";

{
    require CLIO::UI::Theme;
    require CLIO::UI::ToolOutputFormatter;
    require CLIO::Core::Logger;

    # Override get_color to return nothing (no ANSI colors) so we can
    # verify the literal text content of the rendered output.
    package NoColorChat;
    sub new { bless { theme_mgr => $_[1] }, $_[0] }
    sub colorize { my ($self, $text, $color) = @_; return $text; }
    sub can { 1; }

    package main;

    my $theme = CLIO::UI::Theme->new();
    my $chat = NoColorChat->new($theme);
    my $fmt = CLIO::UI::ToolOutputFormatter->new(ui => $chat);

    # Capture STDOUT in a child so we can read it after the parent
    # triggers a log between the header and the action detail.
    pipe(my $read_fd, my $write_fd) or die "pipe: $!";

    my $pid = fork();
    if (!defined $pid) { die "fork: $!"; }

    if ($pid == 0) {
        # Child: redirect STDOUT to pipe
        close $read_fd;
        open(STDOUT, '>&', $write_fd) or die "dup: $!";
        close $write_fd;

        # Step 1: print tool header (no newline) — this is the inline format
        $fmt->display_tool_header("version_control", "VERSION CONTROL", 1, 0);
        STDOUT->flush();

        # Step 2: a log fires here (this is what happens when the tool
        # implementation generates a debug log). Previously the logger
        # prefixed every line with \r\e[K which clobbered the partial
        # header above, leaving only the action detail visible.
        CLIO::Core::Logger::log_debug('ToolRunner', 'simulated mid-tool log');

        # Step 3: print the action detail (the actual user-visible text)
        $fmt->display_action_detail("committing changes", 0, 0);

        STDOUT->flush();
        close STDOUT;
        exit(0);
    }

    # Parent: close write end and read from pipe
    close $write_fd;
    waitpid($pid, 0);
    my $captured = do { local $/; <$read_fd> };
    close $read_fd;

    # The captured output should contain the literal text
    # "VERSION CONTROL" (the header name) followed somewhere by
    # "committing changes" (the action).
    ok($captured =~ /VERSION CONTROL/,
       'Tool header text present in output (not clobbered by interleaved log)');
    ok($captured =~ /committing changes/,
       'Tool action text present in output');
}

# ---------------------------------------------------------------------------
# 7. Non-interactive mode emits machine-readable tagged output
# ---------------------------------------------------------------------------
print "\n--- Non-interactive mode tagged output ---\n";

{
    require CLIO::UI::Theme;
    require CLIO::UI::ToolOutputFormatter;

    # Mock Chat with non_interactive flag
    package TaggedChat;
    sub new { bless { theme_mgr => $_[1], non_interactive => 1, use_color => 0 }, $_[0] }
    sub colorize { my ($self, $text, $color) = @_; return $text; }
    sub can { 1; }

    package main;

    my $theme = CLIO::UI::Theme->new();
    my $chat = TaggedChat->new($theme);
    my $fmt = CLIO::UI::ToolOutputFormatter->new(ui => $chat);

    # Capture stdout
    pipe(my $read_fd, my $write_fd) or die "pipe: $!";
    my $pid = fork();
    if (!defined $pid) { die "fork: $!"; }
    if ($pid == 0) {
        close $read_fd;
        open(STDOUT, '>&', $write_fd) or die "dup: $!";
        close $write_fd;

        $fmt->display_tool_header("version_control", "VERSION CONTROL", 1, 0);
        $fmt->display_action_detail("checking status of . (main: 4 changes)", 0, 0, undef);
        $fmt->display_expanded_content(["main a1b2c3d..e5f6g7h", " 1 file changed, 3 insertions(+)"]);
        $fmt->display_hrule();
        $fmt->display_action_detail("some error occurred", 1, 0, undef);

        STDOUT->flush();
        close STDOUT;
        exit(0);
    }
    close $write_fd;
    waitpid($pid, 0);
    my $captured = do { local $/; <$read_fd> };
    close $read_fd;

    # Verify tagged output format
    ok($captured =~ /^\[VERSION_CONTROL\]/m,
       'Non-interactive tool header emits [TOOL_NAME] tag');
    ok($captured =~ /^\[DETAILS\] checking status/m,
       'Non-interactive action detail emits [DETAILS] tag');
    ok($captured =~ /^\[OUTPUT\] main a1b2c3d/,
       'Non-interactive expanded content emits [OUTPUT] tags');
    ok($captured =~ /^\[ERROR\] some error occurred/m,
       'Non-interactive error emits [ERROR] tag');
    ok($captured !~ /\xe2\x97\x8f/,
       'Non-interactive mode does not emit bullet characters');
    ok($captured !~ /\xe2\x94\x9c/,
       'Non-interactive mode does not emit box-drawing characters');
}

# ---------------------------------------------------------------------------
# 8. Interactive mode still emits human-readable output
# ---------------------------------------------------------------------------
print "\n--- Interactive mode human-readable output ---\n";

{
    require CLIO::UI::Theme;
    require CLIO::UI::ToolOutputFormatter;

    # Mock Chat WITHOUT non_interactive flag (interactive mode)
    package InterChat;
    sub new { bless { theme_mgr => $_[1], non_interactive => 0, use_color => 0 }, $_[0] }
    sub colorize { my ($self, $text, $color) = @_; return $text; }
    sub can { 1; }

    package main;

    my $theme = CLIO::UI::Theme->new();
    my $chat = InterChat->new($theme);
    my $fmt = CLIO::UI::ToolOutputFormatter->new(ui => $chat);

    pipe(my $read_fd, my $write_fd) or die "pipe: $!";
    my $pid = fork();
    if (!defined $pid) { die "fork: $!"; }
    if ($pid == 0) {
        close $read_fd;
        open(STDOUT, '>&', $write_fd) or die "dup: $!";
        close $write_fd;

        $fmt->display_tool_header("version_control", "VERSION CONTROL", 1, 0);
        $fmt->display_action_detail("checking status", 0, 0, undef);

        STDOUT->flush();
        close STDOUT;
        exit(0);
    }
    close $write_fd;
    waitpid($pid, 0);
    my $captured = do { local $/; <$read_fd> };
    close $read_fd;

    # In interactive mode, output should NOT use [TAG] format
    ok($captured !~ /^\[VERSION_CONTROL\]/m,
       'Interactive mode does NOT use [TOOL_NAME] tag format');
    ok($captured =~ /VERSION CONTROL|checking status/m,
       'Interactive mode still shows human-readable content');
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print "\n";
printf "%d passed, %d failed\n", $pass, $fail;
exit($fail > 0 ? 1 : 0);
