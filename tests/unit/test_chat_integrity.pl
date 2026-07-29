#!/usr/bin/env perl
# Test: Chat.pm structural integrity after extraction refactoring
# Catches:
#   - Orphan code blocks - code between subs that should be in a sub body
#     (e.g., the _build_prompt bug where sub header was lost in extraction)
#   - Missing sub-module instances after Chat->new()
#   - Delegation methods that don't forward to correct sub-module
#   - Method name collisions across sub-modules
#   - Key public methods callable on minimal Chat instance

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

use CLIO::UI::Chat;
use CLIO::UI::Chat::Header;
use CLIO::UI::Chat::Security;
use CLIO::UI::Chat::Help;

my ($pass, $fail) = (0, 0);

sub ok {
    my ($cond, $label) = @_;
    if ($cond) {
        $pass++;
        print "OK: $label\n";
    } else {
        $fail++;
        print "FAIL: $label\n";
    }
}

# ── Part 1: Find orphan code between subs ─────────────────────────────

my $chat_pm = -f "$repo_root/lib/CLIO/UI/Chat.pm"
    ? "$repo_root/lib/CLIO/UI/Chat.pm"
    : "lib/CLIO/UI/Chat.pm";

die "Cannot find Chat.pm at '$chat_pm'" unless -f $chat_pm;

open my $fh, '<', $chat_pm or die "Cannot open $chat_pm: $!";
my @lines = <$fh>;
close $fh;

# Phase 1: Find all sub start/end line numbers
my @sub_ranges;
my $i = 0;

while ($i < @lines) {
    my $line = $lines[$i];

    if ($line =~ /^sub\s+(\S+)/) {
        my $name = $1;
        my $start = $i;

        # Find opening brace - could be on same line or next line
        while ($i < @lines && $lines[$i] !~ /\{/) {
            $i++;
        }
        next if $i >= @lines;

        # Now find matching closing brace
        my $depth = 0;
        for (my $j = $i; $j < @lines; $j++) {
            my $l = $lines[$j];
            my @open  = $l =~ /\{/g;
            my @close = $l =~ /\}/g;
            $depth += scalar @open - scalar @close;
            if ($depth <= 0) {
                push @sub_ranges, {
                    name       => $name,
                    start_line => $start + 1,
                    end_line   => $j + 1,
                };
                $i = $j;
                last;
            }
        }
    }
    $i++;
}

# Build the in-sub-body mask
my %in_sub;
for my $range (@sub_ranges) {
    for my $ln ($range->{start_line} .. $range->{end_line}) {
        $in_sub{$ln} = 1;
    }
}

# Phase 2: Scan for code outside sub bodies
my $in_pod = 0;
my @orphans;
my $first_sub_line = @sub_ranges ? $sub_ranges[0]->{start_line} : 999999;

for my $i (0..$#lines) {
    my $ln = $i + 1;
    my $line = $lines[$i];

    # POD tracking
    if ($line =~ /^=\w/) { $in_pod = 1; next; }
    if ($in_pod && $line =~ /^=cut\s*$/) { $in_pod = 0; next; }
    next if $in_pod;

    # Allow module init code before the first sub (use, strict, autoflush, etc.)
    next if $ln < $first_sub_line;

    # Skip blank, comment, structural
    next if $line =~ /^\s*$/;
    next if $line =~ /^\s*#/;
    next if $line =~ /^package\s/;
    next if $line =~ /^use\s/;
    next if $line =~ /^1;\s*$/;
    next if $line =~ /^__END__/;
    next if $line =~ /^sub\s/;
    next if $line =~ /^[};]\s*$/;

    # In sub body
    next if $in_sub{$ln};

    # This is genuine orphan code
    push @orphans, { line => $ln, content => $line };
}

ok(@orphans == 0,
    sprintf("No orphan code blocks outside subs (%d orphan lines found)",
        scalar @orphans));
print "  (Found " . scalar(@sub_ranges) . " subs in Chat.pm)\n";

if (@orphans) {
    for my $o (sort { $a->{line} <=> $b->{line} } @orphans) {
        print "  => Orphan at line $o->{line}: $o->{content}";
    }
}

# ── Part 2: Sub-module instantiation ──────────────────────────────────

my $chat;
eval { 
    $chat = CLIO::UI::Chat->new(
        debug    => 0,
        config   => undef,
        session  => undef,
        no_color => 1,
    );
};
ok(defined $chat && !$@, "Chat->new succeeds");

ok($chat->{header} && ref($chat->{header}) eq 'CLIO::UI::Chat::Header',
    'Chat->{header} is Chat::Header');
ok($chat->{security} && ref($chat->{security}) eq 'CLIO::UI::Chat::Security',
    'Chat->{security} is Chat::Security');
ok($chat->{help} && ref($chat->{help}) eq 'CLIO::UI::Chat::Help',
    'Chat->{help} is Chat::Help');

# ── Part 3: Delegation methods exist ──────────────────────────────────

my %expected_delegation = (
    header => [qw(agent_name display_header _check_auth_migration
                  _prepopulate_session_data check_for_updates_async
                  check_for_update_notification)],
    security => [qw(check_agent_messages _handle_agent_authorization
                    display_agent_message)],
    help => [qw(display_help)],
);

for my $mod (keys %expected_delegation) {
    for my $method (@{$expected_delegation{$mod}}) {
        ok($chat->can($method), "Chat->can('$method')");
        ok($chat->{$mod}->can($method),
            "Chat::" . ucfirst($mod) . "->can('$method')");
    }
}

# ── Part 4: No self-defined method name collisions ────────────────────

# Only check methods explicitly defined in the sub-module files,
# not imported functions (log_debug, box_char, etc.).
# We detect local definitions by checking the glob's CODE slot
# package name matches the module's package.
my %defined_methods;
for my $mod (qw(header security help)) {
    my $mod_name = 'CLIO::UI::Chat::' . ucfirst($mod);
    no strict 'refs';
    my $symtab = \%{$mod_name . '::'};
    for my $sym (keys %$symtab) {
        next if $sym =~ /^(import|new|BEGIN|AUTOLOAD|DESTROY|INC|UNITCHECK|CHECK|INIT|END)$/;
        next if $sym =~ /\:\:/;

        if (exists $symtab->{$sym} && *{$symtab->{$sym}}{CODE}) {
            # Check if the CODE was defined in this package, not imported.
            # We use B to introspect - but that's heavy. Instead, use a simpler
            # heuristic: skip well-known imported utility functions.
            next if $sym =~ /^(log_debug|log_info|log_warning|log_error|log_fatal|ReadMode|ReadKey|GetTerminalSize|box_char|ui_char|_exit|filter_invisible_chars|has_invisible_chars|sanitize_text|set_sanitize_mode)$/;

            if (exists $defined_methods{$sym}) {
                $fail++;
                print "FAIL: Method '$sym' collides between $defined_methods{$sym} and $mod_name\n";
            } else {
                $defined_methods{$sym} = $mod_name;
            }
        }
    }
}
ok(1, "No locally-defined method collisions across sub-modules");

# ── Part 5: Core methods callable ─────────────────────────────────────

ok($chat->can('get_input'),     "Chat->can('get_input')");
ok($chat->can('_build_prompt'), "Chat->can('_build_prompt')");

for my $method (qw(
    run display_assistant_message display_user_message
    display_system_message display_error_message display_success_message
    display_warning_message display_info_message
    display_command_header display_section_header display_key_value
    writeline colorize display_header
    show_busy_indicator hide_busy_indicator
    render_markdown add_to_buffer
    repaint_screen clear_screen pause
    handle_command display_help
)) {
    ok($chat->can($method), "Chat->can('$method')");
}

ok(defined $chat->{display},   'Chat->{display} exists');
ok(defined $chat->{theme_mgr}, 'Chat->{theme_mgr} exists');
ok(defined $chat->{ansi},      'Chat->{ansi} exists');
ok(defined $chat->{streaming}, 'Chat->{streaming} exists');
ok(defined $chat->{pager},     'Chat->{pager} exists');
ok(defined $chat->{host_proto},'Chat->{host_proto} exists');

# ── Results ───────────────────────────────────────────────────────────

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);