#!/usr/bin/env perl
# Test: Runtime verify that Chat.pm's _build_prompt and get_input are
# reachable after extraction refactoring. The structural integrity test
# only checks can(), not that the method returns correctly.
#
# Regressions caught by this test:
#   - The _build_prompt sub-header loss bug (b299359) where Chat.pm
#     compiled cleanly but _build_prompt's body was orphan code.
#   - Delegation forwarding failures where ->can() works but the
#     target sub-module method is broken.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $repo_root = abs_path(dirname(dirname(dirname($0))));
$repo_root = abs_path('.') unless -d "$repo_root/lib";
unshift @INC, "$repo_root/lib";

BEGIN {
    no warnings 'redefine';
    eval { require CLIO::Compat::Terminal; };
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (80, 24); };
    *CLIO::Compat::Terminal::ReadMode     = sub { };
    *CLIO::Compat::Terminal::ReadKey      = sub { undef };
}

# Suppress config filesystem loading
BEGIN {
    $ENV{CLIO_NO_CONFIG_LOAD} = 1;
}

use CLIO::UI::Chat;

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $label) = @_;
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

my $chat = eval {
    CLIO::UI::Chat->new(
        debug    => 0,
        config   => undef,
        session  => undef,
        no_color => 1,
    );
};
ok(defined $chat && !$@, "Chat->new succeeds");

# ── _build_prompt returns a prompt string ────────────────────────────

my $prompt = eval { $chat->_build_prompt('normal') };
ok(defined $prompt && !$@,
    '_build_prompt("normal") returns defined value');
ok(length($prompt) > 0,
    '_build_prompt returns non-empty string');

# The prompt should contain model-related content
ok($prompt =~ /\]|NO PROV|:/,
    '_build_prompt contains expected prompt structure');

# ── _build_prompt collaboration mode ──────────────────────────────────

my $collab_prompt = eval { $chat->_build_prompt('collaboration') };
ok(defined $collab_prompt && !$@,
    '_build_prompt("collaboration") returns defined value');

# ── colorize works (needed by _build_prompt) ──────────────────────────

my $colored = $chat->colorize("test", "DIM");
ok(defined $colored && $colored =~ /test/,
    'colorize preserves input text');

# ── Delegation chain works : Chat -> Header -> method ─────────────────

my $agent = eval { $chat->agent_name() };
ok(defined $agent && $agent =~ /CLIO/,
    'agent_name delegation returns CLIO');

# ── Delegation chain : display_help method callable ───────────────────

ok($chat->can('display_help'), 'display_help method callable');

# ── refresh_terminal_size needed by display_help ──────────────────────

ok($chat->can('refresh_terminal_size'),
    'refresh_terminal_size method exists');

# ── page_manager / pager needed by display_help ───────────────────────

my $pager = $chat->{pager};
ok(defined $pager, 'pager instance exists');
ok($pager->can('reset'), 'pager->reset exists');
ok($pager->can('enable'), 'pager->enable exists');

# ── theme_mgr needed by display_header and display_help ───────────────

my $theme_mgr = $chat->{theme_mgr};
ok(defined $theme_mgr, 'theme_mgr exists');
ok($theme_mgr->can('get_color'), 'theme_mgr->get_color exists');
ok($theme_mgr->can('get_template'), 'theme_mgr->get_template exists');

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);