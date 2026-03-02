#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

# Test counter
my $tests_run = 0;
my $tests_passed = 0;

sub ok {
    my ($condition, $name) = @_;
    $tests_run++;
    if ($condition) {
        $tests_passed++;
        print "ok $tests_run - $name\n";
    } else {
        print "not ok $tests_run - $name\n";
    }
}

sub is {
    my ($got, $expected, $name) = @_;
    $tests_run++;
    if ((!defined $got && !defined $expected) || (defined $got && defined $expected && $got eq $expected)) {
        $tests_passed++;
        print "ok $tests_run - $name\n";
    } else {
        print "not ok $tests_run - $name\n";
        print "#   got: " . ($got // 'undef') . "\n";
        print "#   expected: " . ($expected // 'undef') . "\n";
    }
}

print "# Testing CLIO::UI::Multiplexer\n";
print "# ========================================\n\n";

# ============================================================
# 1. Module Loading
# ============================================================
print "# --- Module Loading ---\n";

eval { require CLIO::UI::Multiplexer };
ok(!$@, "CLIO::UI::Multiplexer loads without error");
if ($@) {
    print "#   Error: $@\n";
}

eval { require CLIO::UI::Multiplexer::Tmux };
ok(!$@, "CLIO::UI::Multiplexer::Tmux loads without error");
if ($@) {
    print "#   Error: $@\n";
}

eval { require CLIO::UI::Multiplexer::Screen };
ok(!$@, "CLIO::UI::Multiplexer::Screen loads without error");
if ($@) {
    print "#   Error: $@\n";
}

eval { require CLIO::UI::Multiplexer::Zellij };
ok(!$@, "CLIO::UI::Multiplexer::Zellij loads without error");
if ($@) {
    print "#   Error: $@\n";
}

eval { require CLIO::UI::Commands::Mux };
ok(!$@, "CLIO::UI::Commands::Mux loads without error");
if ($@) {
    print "#   Error: $@\n";
}

# ============================================================
# 2. Detection - No Multiplexer
# ============================================================
print "\n# --- Detection (no multiplexer) ---\n";

{
    # Save and clear env vars
    my $saved_tmux = delete $ENV{TMUX};
    my $saved_sty = delete $ENV{STY};
    my $saved_zellij = delete $ENV{ZELLIJ};

    my $mux = CLIO::UI::Multiplexer->new();
    ok(!$mux->available(), "No multiplexer detected when env vars unset");
    is($mux->type(), undef, "type() returns undef when no multiplexer");
    is($mux->detect(), undef, "detect() returns undef when no multiplexer");

    # Restore
    $ENV{TMUX} = $saved_tmux if defined $saved_tmux;
    $ENV{STY} = $saved_sty if defined $saved_sty;
    $ENV{ZELLIJ} = $saved_zellij if defined $saved_zellij;
}

# ============================================================
# 3. Detection - tmux
# ============================================================
print "\n# --- Detection (tmux) ---\n";

{
    my $saved_tmux = $ENV{TMUX};
    my $saved_sty = delete $ENV{STY};
    my $saved_zellij = delete $ENV{ZELLIJ};

    $ENV{TMUX} = '/tmp/tmux-1000/default,12345,0';

    my $type = CLIO::UI::Multiplexer->detect();
    is($type, 'tmux', "detect() returns 'tmux' when \$TMUX set");

    # Cleanup
    if (defined $saved_tmux) { $ENV{TMUX} = $saved_tmux } else { delete $ENV{TMUX} }
    $ENV{STY} = $saved_sty if defined $saved_sty;
    $ENV{ZELLIJ} = $saved_zellij if defined $saved_zellij;
}

# ============================================================
# 4. Detection - GNU Screen
# ============================================================
print "\n# --- Detection (screen) ---\n";

{
    my $saved_tmux = delete $ENV{TMUX};
    my $saved_sty = $ENV{STY};
    my $saved_zellij = delete $ENV{ZELLIJ};

    $ENV{STY} = '12345.pts-0.hostname';

    my $type = CLIO::UI::Multiplexer->detect();
    is($type, 'screen', "detect() returns 'screen' when \$STY set");

    # Cleanup
    $ENV{TMUX} = $saved_tmux if defined $saved_tmux;
    if (defined $saved_sty) { $ENV{STY} = $saved_sty } else { delete $ENV{STY} }
    $ENV{ZELLIJ} = $saved_zellij if defined $saved_zellij;
}

# ============================================================
# 5. Detection - Zellij
# ============================================================
print "\n# --- Detection (zellij) ---\n";

{
    my $saved_tmux = delete $ENV{TMUX};
    my $saved_sty = delete $ENV{STY};
    my $saved_zellij = $ENV{ZELLIJ};

    $ENV{ZELLIJ} = '0';

    my $type = CLIO::UI::Multiplexer->detect();
    is($type, 'zellij', "detect() returns 'zellij' when \$ZELLIJ set");

    # Cleanup
    $ENV{TMUX} = $saved_tmux if defined $saved_tmux;
    $ENV{STY} = $saved_sty if defined $saved_sty;
    if (defined $saved_zellij) { $ENV{ZELLIJ} = $saved_zellij } else { delete $ENV{ZELLIJ} }
}

# ============================================================
# 6. Detection Priority - tmux > screen > zellij
# ============================================================
print "\n# --- Detection Priority ---\n";

{
    my $saved_tmux = $ENV{TMUX};
    my $saved_sty = $ENV{STY};
    my $saved_zellij = $ENV{ZELLIJ};

    # Set all three
    $ENV{TMUX} = '/tmp/tmux-test';
    $ENV{STY} = 'test.screen';
    $ENV{ZELLIJ} = '0';

    my $type = CLIO::UI::Multiplexer->detect();
    is($type, 'tmux', "tmux takes priority when all multiplexers detected");

    # Remove tmux, screen should win
    delete $ENV{TMUX};
    $type = CLIO::UI::Multiplexer->detect();
    is($type, 'screen', "screen takes priority over zellij");

    # Remove screen, zellij should win
    delete $ENV{STY};
    $type = CLIO::UI::Multiplexer->detect();
    is($type, 'zellij', "zellij detected when only one present");

    # Cleanup
    if (defined $saved_tmux) { $ENV{TMUX} = $saved_tmux } else { delete $ENV{TMUX} }
    if (defined $saved_sty) { $ENV{STY} = $saved_sty } else { delete $ENV{STY} }
    if (defined $saved_zellij) { $ENV{ZELLIJ} = $saved_zellij } else { delete $ENV{ZELLIJ} }
}

# ============================================================
# 7. Empty env vars should not trigger detection
# ============================================================
print "\n# --- Empty env vars ---\n";

{
    my $saved_tmux = $ENV{TMUX};
    my $saved_sty = $ENV{STY};
    my $saved_zellij = $ENV{ZELLIJ};

    $ENV{TMUX} = '';
    $ENV{STY} = '';
    $ENV{ZELLIJ} = '';

    my $type = CLIO::UI::Multiplexer->detect();
    is($type, undef, "Empty env vars do not trigger detection");

    # Cleanup
    if (defined $saved_tmux) { $ENV{TMUX} = $saved_tmux } else { delete $ENV{TMUX} }
    if (defined $saved_sty) { $ENV{STY} = $saved_sty } else { delete $ENV{STY} }
    if (defined $saved_zellij) { $ENV{ZELLIJ} = $saved_zellij } else { delete $ENV{ZELLIJ} }
}

# ============================================================
# 8. Pane Management (without multiplexer)
# ============================================================
print "\n# --- Pane Management (no mux) ---\n";

{
    my $saved_tmux = delete $ENV{TMUX};
    my $saved_sty = delete $ENV{STY};
    my $saved_zellij = delete $ENV{ZELLIJ};

    my $mux = CLIO::UI::Multiplexer->new();

    my $result = $mux->create_pane(name => 'test', command => 'echo hi');
    is($result, undef, "create_pane returns undef without multiplexer");

    is($mux->kill_pane('fake-id'), 0, "kill_pane returns 0 without multiplexer");

    my $count = $mux->kill_all_panes();
    is($count, 0, "kill_all_panes returns 0 without multiplexer");

    my $panes = $mux->list_panes();
    ok(ref($panes) eq 'HASH' && scalar(keys %$panes) == 0, "list_panes returns empty hash without multiplexer");

    # Cleanup
    $ENV{TMUX} = $saved_tmux if defined $saved_tmux;
    $ENV{STY} = $saved_sty if defined $saved_sty;
    $ENV{ZELLIJ} = $saved_zellij if defined $saved_zellij;
}

# ============================================================
# 9. status_info() structure
# ============================================================
print "\n# --- status_info ---\n";

{
    my $saved_tmux = delete $ENV{TMUX};
    my $saved_sty = delete $ENV{STY};
    my $saved_zellij = delete $ENV{ZELLIJ};

    my $mux = CLIO::UI::Multiplexer->new();
    my $info = $mux->status_info();

    ok(ref($info) eq 'HASH', "status_info returns a hashref");
    is($info->{detected}, 'none', "status_info detected=none when no mux");
    is($info->{available}, 0, "status_info available=0 when no mux");
    is($info->{auto_pane}, 1, "status_info auto_pane=1 by default");
    is($info->{pane_count}, 0, "status_info pane_count=0 initially");
    ok(ref($info->{panes}) eq 'HASH', "status_info panes is a hashref");

    # Cleanup
    $ENV{TMUX} = $saved_tmux if defined $saved_tmux;
    $ENV{STY} = $saved_sty if defined $saved_sty;
    $ENV{ZELLIJ} = $saved_zellij if defined $saved_zellij;
}

# ============================================================
# 10. auto_pane getter/setter
# ============================================================
print "\n# --- auto_pane ---\n";

{
    my $saved_tmux = delete $ENV{TMUX};
    my $saved_sty = delete $ENV{STY};
    my $saved_zellij = delete $ENV{ZELLIJ};

    my $mux = CLIO::UI::Multiplexer->new();
    is($mux->auto_pane(), 1, "auto_pane defaults to 1");

    $mux->auto_pane(0);
    is($mux->auto_pane(), 0, "auto_pane set to 0");

    $mux->auto_pane(1);
    is($mux->auto_pane(), 1, "auto_pane set back to 1");

    my $mux2 = CLIO::UI::Multiplexer->new(auto_pane => 0);
    is($mux2->auto_pane(), 0, "auto_pane=0 via constructor");

    # Cleanup
    $ENV{TMUX} = $saved_tmux if defined $saved_tmux;
    $ENV{STY} = $saved_sty if defined $saved_sty;
    $ENV{ZELLIJ} = $saved_zellij if defined $saved_zellij;
}

# ============================================================
# 11. Tmux driver unit tests (without tmux running)
# ============================================================
print "\n# --- Tmux driver ---\n";

{
    my $driver = CLIO::UI::Multiplexer::Tmux->new();
    ok(ref($driver) eq 'CLIO::UI::Multiplexer::Tmux', "Tmux driver instantiates");
    ok(exists $driver->{tmux_bin}, "Tmux driver has tmux_bin");
    ok(exists $driver->{pane_map}, "Tmux driver has pane_map");

    # pane_exists should return false for non-existent pane
    my $exists = $driver->pane_exists('%999');
    ok(!$exists, "pane_exists returns false for non-existent pane");
}

# ============================================================
# 12. Screen driver unit tests (without screen running)
# ============================================================
print "\n# --- Screen driver ---\n";

{
    my $driver = CLIO::UI::Multiplexer::Screen->new();
    ok(ref($driver) eq 'CLIO::UI::Multiplexer::Screen', "Screen driver instantiates");
    ok(exists $driver->{screen_bin}, "Screen driver has screen_bin");
    ok(exists $driver->{pane_map}, "Screen driver has pane_map");
}

# ============================================================
# 13. Zellij driver unit tests (without zellij running)
# ============================================================
print "\n# --- Zellij driver ---\n";

{
    my $driver = CLIO::UI::Multiplexer::Zellij->new();
    ok(ref($driver) eq 'CLIO::UI::Multiplexer::Zellij', "Zellij driver instantiates");
    ok(exists $driver->{zellij_bin}, "Zellij driver has zellij_bin");
    ok(exists $driver->{pane_map}, "Zellij driver has pane_map");

    # list_panes on empty driver
    my $panes = $driver->list_panes();
    ok(ref($panes) eq 'ARRAY' && scalar(@$panes) == 0, "Zellij list_panes returns empty array initially");
}

# ============================================================
# 14. create_agent_pane convenience method
# ============================================================
print "\n# --- create_agent_pane ---\n";

{
    my $saved_tmux = delete $ENV{TMUX};
    my $saved_sty = delete $ENV{STY};
    my $saved_zellij = delete $ENV{ZELLIJ};

    my $mux = CLIO::UI::Multiplexer->new();
    my $result = $mux->create_agent_pane('agent-1');
    is($result, undef, "create_agent_pane returns undef without multiplexer");

    # Cleanup
    $ENV{TMUX} = $saved_tmux if defined $saved_tmux;
    $ENV{STY} = $saved_sty if defined $saved_sty;
    $ENV{ZELLIJ} = $saved_zellij if defined $saved_zellij;
}

# ============================================================
# Summary
# ============================================================
print "\n# ========================================\n";
print "# Results: $tests_passed/$tests_run tests passed\n";
print "# ========================================\n";

exit($tests_passed == $tests_run ? 0 : 1);
