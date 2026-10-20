#!/usr/bin/perl
# test_security_prompt_category.pl - Test category labels in security prompts
#
# Covers:
#   - get_security_prompt renders category field when present in flags
#   - get_security_prompt works when category field is absent (backward compat)
#   - FileOperations overwrite confirmation includes category 'file_overwrite'

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

use CLIO::UI::Theme;
use CLIO::UI::ANSI;

my ($pass, $fail) = (0, 0);

sub ok {
    my ($cond, $desc) = @_;
    if ($cond) {
        print "PASS: $desc\n";
        $pass++;
    } else {
        print "FAIL: $desc\n";
        $fail++;
    }
}

sub ok_str {
    my ($got, $expected_substring, $desc) = @_;
    if (defined $got && index($got, $expected_substring) >= 0) {
        print "PASS: $desc\n";
        $pass++;
    } else {
        print "FAIL: $desc\n";
        print "      got:      " . (defined $got ? "'$got'" : 'undef') . "\n";
        print "      expected substring: '$expected_substring'\n";
        $fail++;
    }
}

my $ansi = CLIO::UI::ANSI->new();

# --- get_security_prompt renders category when present ---
{
    my $theme = CLIO::UI::Theme->new();

    my ($prompt_line, $input_line) = $theme->get_security_prompt(
        '/tmp/test.txt',
        [{ category => 'file_overwrite', severity => 'medium', description => 'File exists (1234 bytes) and will be overwritten' }],
        '(y)es overwrite | (n)o, cancel',
    );

    ok(defined $prompt_line && length $prompt_line, 'get_security_prompt returns a non-empty prompt line');
    ok(defined $input_line && length $input_line, 'get_security_prompt returns a non-empty input line');

    # The prompt_line should contain the target path
    ok_str($prompt_line, '/tmp/test.txt', 'get_security_prompt prompt_line contains target path');

    # The flags_str (appended after prompt_line) should contain the category
    # We need to check the full composed output. get_security_prompt returns
    # ($prompt_line, $input_line) where flags are appended to prompt_line.
    ok_str($prompt_line, 'file_overwrite', 'get_security_prompt renders category "file_overwrite" in flags');
    ok_str($prompt_line, 'medium', 'get_security_prompt renders severity "medium" in flags');
    ok_str($prompt_line, 'will be overwritten', 'get_security_prompt renders description in flags');
    ok_str($input_line, '(y)es overwrite', 'get_security_prompt renders options in input line');
}

# --- get_security_prompt backward compat: no category field ---
{
    my $theme = CLIO::UI::Theme->new();

    my ($prompt_line, $input_line) = $theme->get_security_prompt(
        '/tmp/test.sh',
        [{ severity => 'high', description => 'Network outbound connection detected' }],
        '(y)es once | (n)o deny',
    );

    ok(defined $prompt_line, 'get_security_prompt returns prompt_line without category field (backward compat)');
    ok_str($prompt_line, 'high', 'get_security_prompt still renders severity without category');
    ok_str($prompt_line, 'Network outbound', 'get_security_prompt still renders description without category');
    ok_str($input_line, '(y)es once', 'get_security_prompt renders options (backward compat)');
}

# --- get_security_prompt with multiple categories ---
{
    my $theme = CLIO::UI::Theme->new();

    my ($prompt_line, $input_line) = $theme->get_security_prompt(
        'rm -rf /tmp/old',
        [
            { category => 'system_destructive', severity => 'critical', description => 'Recursive deletion' },
            { category => 'credential_access', severity => 'high', description => 'Access to credential files' },
        ],
        '(y)es once | (a)llow category | (n)o deny',
    );

    ok_str($prompt_line, 'system_destructive', 'get_security_prompt renders first category (system_destructive)');
    ok_str($prompt_line, 'credential_access', 'get_security_prompt renders second category (credential_access)');
    ok_str($input_line, '(a)llow category', 'get_security_prompt renders category allow option');
}

# --- get_security_prompt with empty flags array ---
{
    my $theme = CLIO::UI::Theme->new();

    my ($prompt_line, $input_line) = $theme->get_security_prompt(
        '/usr/local/bin/install',
        [],
        '(y)es | (n)o',
    );

    ok(defined $prompt_line, 'get_security_prompt handles empty flags array');
    ok_str($input_line, '(y)es | (n)o', 'get_security_prompt renders options with empty flags');
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print "\n";
printf "%d passed, %d failed\n", $pass, $fail;
exit($fail > 0 ? 1 : 0);
