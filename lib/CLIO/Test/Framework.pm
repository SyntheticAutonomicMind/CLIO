package CLIO::Test::Framework;

use strict;
use warnings;
use Time::HiRes qw(time);
use File::Basename;

=head1 NAME

CLIO::Test::Framework - Comprehensive testing framework for CLIO

=head1 SYNOPSIS

    use CLIO::Test::Framework;
    
    my $test = CLIO::Test::Framework->new(debug => 1);
    $test->run_test_suite('code_intelligence');
    my $results = $test->get_results();

=head1 DESCRIPTION

This module provides a comprehensive testing framework for all CLIO
components, including unit tests, integration tests, and performance tests.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} || 0,
        verbose => $args{verbose} || 0,
        results => [],
        stats => {
            total_tests => 0,
            passed => 0,
            failed => 0,
            skipped => 0,
            start_time => 0,
            end_time => 0
        },
        current_suite => '',
        current_test => ''
    };
    
    return bless $self, $class;
}

=head2 run_test_suite($suite_name)

Run a complete test suite.

=cut

sub run_test_suite {
    my ($self, $suite_name) = @_;
    
    $self->{current_suite} = $suite_name;
    $self->{stats}->{start_time} = time();
    
    $self->_log("Starting test suite: $suite_name");
    
    # Available test suites
    my %suites = (
        'code_intelligence' => \&_test_code_intelligence,
        'tree_sitter' => \&_test_tree_sitter,
        'symbols' => \&_test_symbols,
        'relations' => \&_test_relations,
        'security' => \&_test_security,
        'integration' => \&_test_integration,
        'all' => \&_test_all
    );
    
    if (exists $suites{$suite_name}) {
        $suites{$suite_name}->($self);
    } else {
        $self->_fail("Unknown test suite: $suite_name");
        return 0;
    }
    
    $self->{stats}->{end_time} = time();
    $self->_print_summary();
    
    return $self->{stats}->{failed} == 0;
}

=head2 _test_code_intelligence($self)

Test the complete code intelligence system.

=cut

sub _test_code_intelligence {
    my ($self) = @_;
    
    $self->_log("Testing Code Intelligence System");
    
    # Test TreeSitter integration
    $self->_test_tree_sitter();
    
    # Test Symbol management
    $self->_test_symbols();
    
    # Test Relationship mapping
    $self->_test_relations();
    
    # Test integration
    $self->_test_code_intelligence_integration();
}

=head2 _test_tree_sitter($self)

Test TreeSitter functionality.

=cut

sub _test_tree_sitter {
    my ($self) = @_;
    
    $self->_log("Testing TreeSitter Module");
    
    # Test module loading
    $self->_test("TreeSitter module loads", sub {
        eval "use CLIO::Code::TreeSitter";
        return !$@;
    });
    
    # Test instance creation
    my $ts;
    $self->_test("TreeSitter instance creation", sub {
        eval { $ts = CLIO::Code::TreeSitter->new(debug => $self->{debug}) };
        return !$@ && defined $ts;
    });
    
    return unless $ts;
    
    # Test supported languages
    $self->_test("Get supported languages", sub {
        my @langs = $ts->get_supported_languages();
        return scalar(@langs) > 0;
    });
    
    # Test Perl code parsing
    my $perl_code = <<'CODE';
package Test::Module;
use strict;
use warnings;

my $variable = 42;
our $global = "test";

sub hello_world {
    my ($name) = @_;
    return "Hello, $name!";
}

1;
CODE
    
    my $ast;
    $self->_test("Parse Perl code", sub {
        eval { $ast = $ts->parse_code($perl_code, 'perl') };
        return !$@ && defined $ast && $ast->{language} eq 'perl';
    });
    
    return unless $ast;
    
    # Test symbol extraction
    $self->_test("Extract symbols from AST", sub {
        my $symbols = $ts->extract_symbols($ast);
        return defined $symbols && ref($symbols) eq 'ARRAY' && @$symbols > 0;
    });
    
    # Test file analysis
    $self->_test("Analyze Perl file", sub {
        # Create a temporary test file
        my $test_file = "/tmp/test_analysis.pl";
        open my $fh, '>', $test_file or return 0;
        print $fh $perl_code;
        close $fh;
        
        my $analysis = $ts->analyze_file($test_file);
        unlink $test_file;
        
        return defined $analysis && 
               $analysis->{language} eq 'perl' &&
               defined $analysis->{symbols} &&
               @{$analysis->{symbols}} > 0;
    });
}

=head2 _test_symbols($self)

Test Symbol management functionality.

=cut

sub _test_symbols {
    my ($self) = @_;
    
    $self->_log("Testing Symbol Management");
    
    # Test module loading
    $self->_test("Symbol module loads", sub {
        eval "use CLIO::Code::Symbols";
        return !$@;
    });
    
    # Test instance creation
    my $symbols;
    $self->_test("Symbol manager creation", sub {
        eval { $symbols = CLIO::Code::Symbols->new(debug => $self->{debug}) };
        return !$@ && defined $symbols;
    });
    
    return unless $symbols;
    
    # Create test file for indexing
    my $test_file = "/tmp/test_symbols.pl";
    my $test_code = <<'CODE';
package TestSymbols;

sub function_one {
    my $local_var = 42;
    return $local_var;
}

sub function_two {
    my ($param) = @_;
    return function_one() + $param;
}

our $global_var = "test";

1;
CODE
    
    open my $fh, '>', $test_file or return;
    print $fh $test_code;
    close $fh;
    
    # Test file indexing
    $self->_test("Index file symbols", sub {
        my $count = $symbols->index_file($test_file);
        return $count > 0;
    });
    
    # Test symbol finding
    $self->_test("Find symbols by name", sub {
        my $results = $symbols->find_symbols('function_one');
        return defined $results && @$results > 0;
    });
    
    # Test file symbols
    $self->_test("Get file symbols", sub {
        my $file_symbols = $symbols->get_file_symbols($test_file);
        return defined $file_symbols && @$file_symbols > 0;
    });
    
    # Test statistics
    $self->_test("Get symbol statistics", sub {
        my $stats = $symbols->get_statistics();
        return defined $stats && 
               $stats->{indexed_files} > 0 &&
               $stats->{total_symbols} > 0;
    });
    
    # Cleanup
    unlink $test_file;
    $symbols->clear_index();
}

=head2 _test_relations($self)

Test Relationship mapping functionality.

=cut

sub _test_relations {
    my ($self) = @_;
    
    $self->_log("Testing Relationship Mapping");
    
    # Test module loading
    $self->_test("Relations module loads", sub {
        eval "use CLIO::Code::Relations";
        return !$@;
    });
    
    # Test instance creation
    my $relations;
    $self->_test("Relations manager creation", sub {
        eval { $relations = CLIO::Code::Relations->new(debug => $self->{debug}) };
        return !$@ && defined $relations;
    });
    
    return unless $relations;
    
    # Create test file with dependencies
    my $test_file = "/tmp/test_relations.pl";
    my $test_code = <<'CODE';
package TestRelations;
use strict;
use warnings;
use JSON;
use TestModule;

sub caller_function {
    my $result = callee_function();
    return TestModule::some_function($result);
}

sub callee_function {
    return 42;
}

1;
CODE
    
    open my $fh, '>', $test_file or return;
    print $fh $test_code;
    close $fh;
    
    # Test dependency analysis
    $self->_test("Analyze file dependencies", sub {
        return $relations->analyze_dependencies($test_file);
    });
    
    # Test statistics
    $self->_test("Get relation statistics", sub {
        my $stats = $relations->get_statistics();
        return defined $stats && ref($stats) eq 'HASH';
    });
    
    # Test circular dependency detection
    $self->_test("Detect circular dependencies", sub {
        my $cycles = $relations->find_circular_dependencies();
        return defined $cycles && ref($cycles) eq 'ARRAY';
    });
    
    # Test graph export
    $self->_test("Export dependency graph", sub {
        my $json_graph = $relations->export_graph('json');
        return defined $json_graph && length($json_graph) > 0;
    });
    
    # Cleanup
    unlink $test_file;
}

=head2 _test_security($self)

Test Security Framework functionality.

=cut

sub _test_security {
    my ($self) = @_;
    
    $self->_log("Testing Security Framework");
    
    # Test Authentication module
    $self->_test("Authentication module loads", sub {
        eval "use CLIO::Security::Auth";
        return !$@;
    });
    
    my $auth;
    $self->_test("Auth instance creation", sub {
        eval { $auth = CLIO::Security::Auth->new(debug => 0) };
        return !$@ && defined $auth;
    });
    
    return unless $auth;
    
    # Test authentication flow
    my $token;
    $self->_test("User authentication", sub {
        $token = $auth->authenticate('testuser', 'password');
        return defined $token;
    });
    
    $self->_test("Token validation", sub {
        my $token_data = $auth->validate_token($token);
        return defined $token_data && $token_data->{user_id} eq 'testuser';
    });
    
    # Test Authorization module
    $self->_test("Authorization module loads", sub {
        eval "use CLIO::Security::Authz";
        return !$@;
    });
    
    my $authz;
    $self->_test("Authz instance creation", sub {
        eval { $authz = CLIO::Security::Authz->new(debug => 0) };
        return !$@ && defined $authz;
    });
    
    return unless $authz;
    
    # Test authorization flow
    $self->_test("Role assignment", sub {
        return $authz->assign_role('testuser', 'user');
    });
    
    $self->_test("Permission check", sub {
        return $authz->check_permission('testuser', 'read', '/api/test');
    });
    
    # Test Security Manager
    $self->_test("Security Manager module loads", sub {
        eval "use CLIO::Security::Manager";
        return !$@;
    });
    
    my $security;
    $self->_test("Security Manager creation", sub {
        eval { $security = CLIO::Security::Manager->new(debug => 0) };
        return !$@ && defined $security;
    });
    
    return unless $security;
    
    # Test integrated security
    my $mgr_token;
    $self->_test("Integrated authentication", sub {
        $mgr_token = $security->authenticate('manager_user', 'password');
        return defined $mgr_token;
    });
    
    $self->_test("Integrated authorization", sub {
        return $security->authorize($mgr_token, 'read', '/api/data');
    });
    
    $self->_test("Input validation", sub {
        return $security->validate_input('safe_input') && !$security->validate_input('<script>');
    });
    
    $self->_test("Security cleanup", sub {
        my $cleaned = $security->cleanup();
        return defined $cleaned;
    });
}

=head2 _test_code_intelligence_integration($self)

Test integration between all code intelligence components.

=cut

sub _test_code_intelligence_integration {
    my ($self) = @_;
    
    $self->_log("Testing Code Intelligence Integration");
    
    # Create integrated test
    $self->_test("Full code intelligence workflow", sub {
        eval {
            # Initialize components
            my $ts = CLIO::Code::TreeSitter->new(debug => 0);
            my $symbols = CLIO::Code::Symbols->new(debug => 0);
            my $relations = CLIO::Code::Relations->new(debug => 0);
            
            # Set up integration
            $symbols->set_tree_sitter($ts);
            $relations->set_symbol_manager($symbols);
            
            # Create test file
            my $test_file = "/tmp/integration_test.pl";
            open my $fh, '>', $test_file;
            print $fh <<'CODE';
package IntegrationTest;
use strict;

sub main_function {
    my $result = helper_function();
    return process_result($result);
}

sub helper_function {
    return 42;
}

sub process_result {
    my ($value) = @_;
    return $value * 2;
}

1;
CODE
            close $fh;
            
            # Run full analysis
            my $analysis = $ts->analyze_file($test_file);
            my $symbol_count = $symbols->index_file($test_file);
            my $deps_success = $relations->analyze_dependencies($test_file);
            
            # Cleanup
            unlink $test_file;
            
            return defined $analysis && 
                   $symbol_count > 0 && 
                   $deps_success;
        };
        
        return !$@;
    });
}

=head2 _test_all($self)

Run all available tests.

=cut

sub _test_all {
    my ($self) = @_;
    
    $self->_log("Running Complete Test Suite");
    
    $self->_test_tree_sitter();
    $self->_test_symbols();
    $self->_test_relations();
    $self->_test_code_intelligence_integration();
    $self->_test_security();
}

=head2 _test($name, $code_ref)

Run a single test.

=cut

sub _test {
    my ($self, $name, $code_ref) = @_;
    
    $self->{current_test} = $name;
    $self->{stats}->{total_tests}++;
    
    my $start_time = time();
    my $success = 0;
    my $error = '';
    
    eval {
        $success = $code_ref->();
    };
    
    if ($@) {
        $error = $@;
        $success = 0;
    }
    
    my $duration = time() - $start_time;
    
    my $result = {
        name => $name,
        suite => $self->{current_suite},
        success => $success,
        error => $error,
        duration => $duration,
        timestamp => time()
    };
    
    push @{$self->{results}}, $result;
    
    if ($success) {
        $self->{stats}->{passed}++;
        $self->_log("✓ $name (" . sprintf("%.3f", $duration) . "s)");
    } else {
        $self->{stats}->{failed}++;
        $self->_log("✗ $name - $error (" . sprintf("%.3f", $duration) . "s)");
    }
}

=head2 _fail($message)

Record a test failure.

=cut

sub _fail {
    my ($self, $message) = @_;
    
    $self->{stats}->{failed}++;
    $self->_log("✗ FAILED: $message");
}

=head2 _log($message)

Log a test message.

=cut

sub _log {
    my ($self, $message) = @_;
    
    my $timestamp = sprintf("[%.3f]", time());
    print "$timestamp $message\n" if $self->{verbose} || $self->{debug};
}

=head2 get_results()

Get test results.

=cut

sub get_results {
    my ($self) = @_;
    
    return {
        results => $self->{results},
        stats => $self->{stats}
    };
}

=head2 _print_summary()

Print test summary.

=cut

sub _print_summary {
    my ($self) = @_;
    
    my $duration = $self->{stats}->{end_time} - $self->{stats}->{start_time};
    
    print "\n" . "="x60 . "\n";
    print "TEST SUMMARY\n";
    print "="x60 . "\n";
    print "Suite: $self->{current_suite}\n";
    print "Total Tests: $self->{stats}->{total_tests}\n";
    print "Passed: $self->{stats}->{passed}\n";
    print "Failed: $self->{stats}->{failed}\n";
    print "Duration: " . sprintf("%.3f", $duration) . "s\n";
    
    if ($self->{stats}->{failed} == 0) {
        print "Result: ✓ ALL TESTS PASSED\n";
    } else {
        print "Result: ✗ " . $self->{stats}->{failed} . " TESTS FAILED\n";
    }
    
    print "="x60 . "\n\n";
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 COPYRIGHT

Copyright (c) 2025 CLIO Project. All rights reserved.

=cut
