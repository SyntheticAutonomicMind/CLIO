#!/usr/bin/env perl

# Unit tests for CLIO::Util::PathResolver - specifically find_clio_dir

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Spec;
use File::Path qw(make_path remove_tree);
use Cwd qw(abs_path);

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

sub like {
    my ($got, $regex, $desc) = @_;
    if (defined($got) && $got =~ $regex) {
        print "PASS: $desc\n"; $pass++;
    } else {
        $got //= '(undef)';
        print "FAIL: $desc\n      got:      $got\n      expected: match $regex\n"; $fail++;
    }
}

sub use_ok: {
    my $ok = CLIO::Util::PathResolver->can('find_clio_dir');
    ok($ok, 'find_clio_dir is a callable method');
}

print "\n--- find_clio_dir exports and works ---\n";

{
    require CLIO::Util::PathResolver;
    use_ok: {
        my $ok = CLIO::Util::PathResolver->can('find_clio_dir');
        ok($ok, 'find_clio_dir is a callable method');
    }

    # Test exported
    my @exports = @CLIO::Util::PathResolver::EXPORT_OK;
    ok(grep(/find_clio_dir/, @exports), 'find_clio_dir is in EXPORT_OK list');

    # Test it finds the project root from a subdirectory
    my $dir = CLIO::Util::PathResolver::find_clio_dir("$RealBin/../../lib/CLIO/Core");
    ok(-d File::Spec->catdir($dir, '.clio'), 'find_clio_dir finds project root containing .clio/');

    # Test it returns a usable path
    ok(-d $dir, 'find_clio_dir returns an existing directory');
}

print "\n--- find_clio_dir works in PromptBuilder ---\n";

{
    require CLIO::Core::PromptBuilder;
    my $pb = CLIO::Core::PromptBuilder->new();
    ok($pb, 'PromptBuilder can be instantiated without find_clio_dir errors');
    # _read_session_goals / get_user_context (the old <sessionContext>
    # XML path) were removed in the role-based history refactor; the
    # live path now renders the environment via the ContextBuilder
    # projection. The constructor check above still exercises find_clio_dir
    # avoidance at construction time.
}

print "\n--- Project data directory resolution ---\n";

{
    use File::Temp qw(tempdir);
    my $tmp = tempdir(CLEANUP => 1);

    # Save and restore env + cache state for isolation
    my $orig_cwd = Cwd::getcwd();
    my $orig_config_dir = $CLIO::Util::PathResolver::CONFIG_DIR;
    my $orig_project_data = $CLIO::Util::PathResolver::PROJECT_DATA_DIR;
    my $orig_project_uuid = $CLIO::Util::PathResolver::PROJECT_UUID;
    local $CLIO::Util::PathResolver::CONFIG_DIR = undef;
    local $CLIO::Util::PathResolver::PROJECT_DATA_DIR = undef;
    local $CLIO::Util::PathResolver::PROJECT_UUID = undef;

    # Set up a fake project with .clio/
    chdir $tmp;
    make_path('.clio');

    CLIO::Util::PathResolver::init(base_dir => $tmp);

    # Test get_project_data_dir creates .clio/project_uuid and returns project dir
    my $data_dir = CLIO::Util::PathResolver::get_project_data_dir();
    ok(defined $data_dir, 'get_project_data_dir returns a path');
    ok($data_dir =~ m{projects[/\\]}, 'data dir contains projects/ component');
    like($data_dir, qr{[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}}, 'data dir contains a UUID v4');
    ok(-f '.clio/project_uuid', '.clio/project_uuid file created');
    my $uuid_content = do { local $/; open my $fh, '<', '.clio/project_uuid'; <$fh> };
    like($uuid_content, qr{^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$}, 'project_uuid file contains valid UUID');

    # Test get_project_sessions_dir creates sessions subdirectory
    my $sessions_dir = CLIO::Util::PathResolver::get_project_sessions_dir();
    ok(-d $sessions_dir, 'project sessions directory created');
    ok($sessions_dir eq File::Spec->catdir($data_dir, 'sessions'), 'sessions dir is under data dir');

    # Test get_session_file / get_project_session_file
    my $session_file = CLIO::Util::PathResolver::get_session_file('test-session-id');
    like($session_file, qr{test-session-id\.json$}, 'session file ends with session id');
    like($session_file, qr{sessions}, 'session file is in sessions dir');

    # Test get_project_ltm_file
    my $ltm_file = CLIO::Util::PathResolver::get_project_ltm_file();
    ok(defined $ltm_file, 'get_project_ltm_file returns a path');
    like($ltm_file, qr{ltm\.json$}, 'ltm file ends with ltm.json');
    like($ltm_file, qr{projects}, 'ltm file is under projects dir');

    # Test get_project_memory_dir
    my $memory_dir = CLIO::Util::PathResolver::get_project_memory_dir();
    ok(-d $memory_dir, 'project memory directory created');
    like($memory_dir, qr{memory$}, 'memory dir ends with memory');

    # Test get_project_vault_dir
    my $vault_dir = CLIO::Util::PathResolver::get_project_vault_dir();
    ok(-d $vault_dir, 'project vault directory created');
    like($vault_dir, qr{vault$}, 'vault dir ends with vault');

    # Test get_project_logs_dir
    my $logs_dir = CLIO::Util::PathResolver::get_project_logs_dir();
    ok(-d $logs_dir, 'project logs directory created');
    like($logs_dir, qr{logs$}, 'logs dir ends with logs');

    # Test idempotency: second call returns cached value
    my $data_dir2 = CLIO::Util::PathResolver::get_project_data_dir();
    is($data_dir, $data_dir2, 'get_project_data_dir returns cached value on second call');

    # Test get_project_data_dir_for resolves a specific project
    my $data_dir_for = CLIO::Util::PathResolver::get_project_data_dir_for($tmp);
    ok(defined $data_dir_for, 'get_project_data_dir_for returns path for known project');
    is($data_dir_for, $data_dir, 'get_project_data_dir_for returns same path as get_project_data_dir');

    # Test get_project_data_dir_for returns undef for unknown project (no uuid)
    my $unknown_dir = tempdir(CLEANUP => 1);
    make_path(File::Spec->catdir($unknown_dir, '.clio'));
    my $unknown_data = CLIO::Util::PathResolver::get_project_data_dir_for($unknown_dir);
    ok(!defined $unknown_data, 'get_project_data_dir_for returns undef for project without uuid');

    # Restore
    chdir $orig_cwd;
    $CLIO::Util::PathResolver::CONFIG_DIR = $orig_config_dir;
    $CLIO::Util::PathResolver::PROJECT_DATA_DIR = $orig_project_data;
    $CLIO::Util::PathResolver::PROJECT_UUID = $orig_project_uuid;
}

print "\n--- One-time migration from old .clio/ paths ---\n";

{
    use File::Temp qw(tempdir);
    use CLIO::Util::JSON qw(encode_json);
    my $orig_cwd = Cwd::getcwd();
    my $orig_config_dir = $CLIO::Util::PathResolver::CONFIG_DIR;
    my $orig_project_data = $CLIO::Util::PathResolver::PROJECT_DATA_DIR;
    my $orig_project_uuid = $CLIO::Util::PathResolver::PROJECT_UUID;
    my $tmp = tempdir(CLEANUP => 1);

    # Set up a fake project with OLD-style .clio/ data
    chdir $tmp;
    make_path('.clio/sessions');
    make_path('.clio/memory');
    make_path('.clio/logs');
    make_path('.clio/vault');

    # Write dummy old session file
    open my $fh, '>:raw', '.clio/sessions/old-session.json' or die;
    print $fh encode_json({ history => [{ role => 'user', content => 'hello' }] });
    close $fh;

    # Write dummy old ltm.json
    open my $fh2, '>:raw', '.clio/ltm.json' or die;
    print $fh2 encode_json({ discoveries => [] });
    close $fh2;

    # Write dummy old memory file
    open my $fh3, '>:raw', '.clio/memory/old-key.json' or die;
    print $fh3 encode_json({ key => 'old-key', content => 'old content' });
    close $fh3;

    # Isolated config dir
    my $config_base = tempdir(CLEANUP => 1);
    local $CLIO::Util::PathResolver::CONFIG_DIR = undef;
    local $CLIO::Util::PathResolver::PROJECT_DATA_DIR = undef;
    local $CLIO::Util::PathResolver::PROJECT_UUID = undef;

    CLIO::Util::PathResolver::init(base_dir => $config_base);

    # Trigger project data dir resolution (generates UUID + runs migration)
    my $data_dir = CLIO::Util::PathResolver::get_project_data_dir();

    # Verify UUID was generated
    ok(-f '.clio/project_uuid', 'project_uuid created on first launch');

    # Verify old sessions were moved
    my $new_sessions_dir = File::Spec->catdir($data_dir, 'sessions');
    ok(-d $new_sessions_dir, 'sessions dir created in new location');
    my @new_files = glob("$new_sessions_dir/old-session.json");
    ok(@new_files, 'old session file migrated to new location');
    ok(!-e '.clio/sessions/old-session.json', 'old session file removed from project dir');

    # Verify old ltm.json was moved
    my $new_ltm = File::Spec->catfile($data_dir, 'ltm.json');
    ok(-f $new_ltm, 'ltm.json migrated to new location');
    ok(!-f '.clio/ltm.json', 'ltm.json removed from project dir');

    # Verify old memory files were moved
    my $new_memory_dir = File::Spec->catdir($data_dir, 'memory');
    ok(-d $new_memory_dir, 'memory dir migrated to new location');
    my @mem_files = glob("$new_memory_dir/old-key.json");
    ok(@mem_files, 'old memory file migrated to new location');

    # Verify vault was migrated (empty dir should be moved)
    ok(-d File::Spec->catdir($data_dir, 'vault'), 'vault dir migrated to new location');

    # Verify logs can be created in new location
    my $logs_dir = CLIO::Util::PathResolver::get_project_logs_dir();
    ok(-d $logs_dir, 'logs dir created in new location');
    ok(!-d '.clio/logs', 'logs dir removed from project dir');

    # Restore
    chdir $orig_cwd;
    $CLIO::Util::PathResolver::CONFIG_DIR = $orig_config_dir;
    $CLIO::Util::PathResolver::PROJECT_DATA_DIR = $orig_project_data;
    $CLIO::Util::PathResolver::PROJECT_UUID = $orig_project_uuid;
}

print "\n";
printf "%d passed, %d failed\n", $pass, $fail;
exit($fail > 0 ? 1 : 0);
