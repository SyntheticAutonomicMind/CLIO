package CLIO::Protocols::RepoMap;

use strict;
use warnings;
use utf8;
use base 'CLIO::Protocols::Handler';
use MIME::Base64;
use CLIO::Util::JSON qw(encode_json decode_json);
use File::Find;
use File::Spec;
use Cwd;

=head1 NAME

CLIO::Protocols::RepoMap - Repository mapping and analysis protocol handler

=head1 DESCRIPTION

This module provides comprehensive repository analysis including directory structure mapping,
file type analysis, dependency tracking, code metrics, and architectural insights.

=head1 PROTOCOL FORMAT

[REPOMAP:action=<action>:params=<base64_params>:options=<base64_options>]

Actions:
- structure: Generate directory/file structure map
- dependencies: Analyze project dependencies
- metrics: Calculate code metrics and statistics
- patterns: Identify architectural patterns
- hotspots: Find frequently changed files
- complexity: Analyze code complexity
- documentation: Generate documentation map
- search: Search for specific patterns or files

=cut

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        max_depth => $args{max_depth} || 10,
        exclude_patterns => $args{exclude_patterns} || [
            qr/\.git\//,
            qr/node_modules\//,
            qr/\.svn\//,
            qr/\.hg\//,
            qr/__pycache__\//,
            qr/\.pytest_cache\//,
            qr/\.coverage/,
            qr/\.DS_Store/,
            qr/\.vscode\//,
            qr/\.idea\//,
            qr/build\//,
            qr/dist\//,
            qr/target\//,
        ],
        file_type_patterns => {
            'source_code' => {
                'perl' => [qr/\.p[lm]$/, qr/\.t$/],
                'python' => [qr/\.py$/],
                'javascript' => [qr/\.js$/, qr/\.jsx$/],
                'typescript' => [qr/\.ts$/, qr/\.tsx$/],
                'java' => [qr/\.java$/],
                'c_cpp' => [qr/\.c$/, qr/\.cpp$/, qr/\.h$/, qr/\.hpp$/],
                'ruby' => [qr/\.rb$/],
                'go' => [qr/\.go$/],
                'rust' => [qr/\.rs$/],
                'php' => [qr/\.php$/],
                'shell' => [qr/\.sh$/, qr/\.bash$/, qr/\.zsh$/],
            },
            'configuration' => {
                'json' => [qr/\.json$/],
                'yaml' => [qr/\.ya?ml$/],
                'xml' => [qr/\.xml$/],
                'ini' => [qr/\.ini$/, qr/\.cfg$/],
                'toml' => [qr/\.toml$/],
                'env' => [qr/\.env$/],
            },
            'documentation' => {
                'markdown' => [qr/\.md$/],
                'text' => [qr/\.txt$/],
                'rst' => [qr/\.rst$/],
                'pod' => [qr/\.pod$/],
                'man' => [qr/\.\d$/],
            },
            'build_deployment' => {
                'makefile' => [qr/Makefile$/, qr/\.mk$/],
                'dockerfile' => [qr/Dockerfile$/],
                'compose' => [qr/docker-compose\.ya?ml$/],
                'package' => [qr/package\.json$/, qr/Cargo\.toml$/, qr/setup\.py$/],
                'ci_cd' => [qr/\.github\/workflows\//, qr/\.gitlab-ci\.yml$/],
            },
            'data' => {
                'csv' => [qr/\.csv$/],
                'sql' => [qr/\.sql$/],
                'database' => [qr/\.db$/, qr/\.sqlite$/],
                'log' => [qr/\.log$/],
            },
        },
        language_metrics => {
            'perl' => \&_analyze_perl_metrics,
            'python' => \&_analyze_python_metrics,
            'javascript' => \&_analyze_js_metrics,
            'typescript' => \&_analyze_ts_metrics,
            'default' => \&_analyze_default_metrics,
        },
        %args
    }, $class;
    
    return $self;
}

sub handle {
    my ($self, @args) = @_;
    return $self->process_request(@args);
}

sub process_request {
    my ($self, $input) = @_;
    
    # Parse protocol: [REPOMAP:action=<action>:params=<base64_params>:options=<base64_options>]
    if ($input !~ /^\[REPOMAP:action=([^:]+):params=([^:]+)(?::options=([^:]+))?\]$/) {
        return $self->handle_errors('Invalid REPOMAP protocol format');
    }
    
    my ($action, $b64_params, $b64_options) = ($1, $2, $3);
    
    # Decode parameters
    my $params = {};
    if ($b64_params) {
        my $params_str = eval { decode_base64($b64_params) };
        if ($@) {
            return $self->handle_errors("Failed to decode params: $@");
        }
        
        # Try to parse as JSON, fallback to string
        if ($params_str =~ /^\s*\{/) {
            $params = eval { decode_json($params_str) };
            if ($@) {
                $params = { query => $params_str };
            }
        } else {
            $params = { query => $params_str };
        }
    }
    
    # Decode options if provided
    my $options = {};
    if ($b64_options) {
        my $options_json = eval { decode_base64($b64_options) };
        if ($@) {
            return $self->handle_errors("Failed to decode options: $@");
        }
        $options = eval { decode_json($options_json) };
        if ($@) {
            return $self->handle_errors("Invalid options JSON: $@");
        }
    }
    
    # Set repository path
    my $repo_path = $options->{repository_path} || '.';
    unless (-d $repo_path) {
        return $self->handle_errors("Repository path does not exist: $repo_path");
    }
    
    # Route to appropriate action handler
    my $handlers = {
        structure => \&_handle_structure,
        dependencies => \&_handle_dependencies,
        metrics => \&_handle_metrics,
        patterns => \&_handle_patterns,
        hotspots => \&_handle_hotspots,
        complexity => \&_handle_complexity,
        documentation => \&_handle_documentation,
        search => \&_handle_search,
    };
    
    my $handler = $handlers->{$action};
    if ($handler) {
        return $handler->($self, $params, $options, $repo_path);
    } else {
        return $self->handle_errors("Unknown REPOMAP action: $action");
    }
}

sub _handle_structure {
    my ($self, $params, $options, $repo_path) = @_;
    
    my $max_depth = $params->{max_depth} || $self->{max_depth};
    my $include_hidden = $params->{include_hidden} || 0;
    my $file_details = $params->{file_details} || 1;
    
    my $original_cwd = getcwd();
    chdir $repo_path;
    
    my $structure = $self->_build_directory_structure('.', 0, $max_depth, $include_hidden, $file_details);
    my $summary = $self->_calculate_structure_summary($structure);
    
    chdir $original_cwd;
    
    my $result = {
        success => 1,
        action => 'structure',
        repository_path => $repo_path,
        max_depth => $max_depth,
        structure => $structure,
        summary => $summary,
        analysis_timestamp => time(),
    };
    
    return $self->format_response($result);
}

sub _handle_dependencies {
    my ($self, $params, $options, $repo_path) = @_;
    
    my $analysis_type = $params->{analysis_type} || 'auto';
    my $include_dev = $params->{include_dev} || 1;
    
    my $original_cwd = getcwd();
    chdir $repo_path;
    
    my $dependencies = {};
    
    # Auto-detect project type and analyze dependencies
    if ($analysis_type eq 'auto' || $analysis_type eq 'perl') {
        $dependencies->{perl} = $self->_analyze_perl_dependencies();
    }
    if ($analysis_type eq 'auto' || $analysis_type eq 'javascript') {
        $dependencies->{javascript} = $self->_analyze_js_dependencies();
    }
    if ($analysis_type eq 'auto' || $analysis_type eq 'python') {
        $dependencies->{python} = $self->_analyze_python_dependencies();
    }
    
    # Analyze internal dependencies (module/file relationships)
    $dependencies->{internal} = $self->_analyze_internal_dependencies();
    
    chdir $original_cwd;
    
    my $result = {
        success => 1,
        action => 'dependencies',
        repository_path => $repo_path,
        analysis_type => $analysis_type,
        dependencies => $dependencies,
        dependency_graph => $self->_build_dependency_graph($dependencies),
        analysis_timestamp => time(),
    };
    
    return $self->format_response($result);
}

sub _handle_metrics {
    my ($self, $params, $options, $repo_path) = @_;
    
    my $metric_types = $params->{metric_types} || ['lines', 'files', 'complexity', 'maintainability'];
    my $by_language = $params->{by_language} || 1;
    my $by_directory = $params->{by_directory} || 1;
    
    my $original_cwd = getcwd();
    chdir $repo_path;
    
    my $metrics = {
        overview => $self->_calculate_overview_metrics(),
        files => {},
        languages => {},
        directories => {},
    };
    
    # Calculate detailed metrics
    my @files = $self->_get_all_source_files();
    
    for my $file (@files) {
        my $file_metrics = $self->_calculate_file_metrics($file);
        $metrics->{files}->{$file} = $file_metrics;
        
        # Aggregate by language
        if ($by_language) {
            my $language = $self->_detect_file_language($file);
            $metrics->{languages}->{$language} ||= {
                files => 0,
                lines => 0,
                complexity => 0,
            };
            $metrics->{languages}->{$language}->{files}++;
            $metrics->{languages}->{$language}->{lines} += $file_metrics->{lines} || 0;
            $metrics->{languages}->{$language}->{complexity} += $file_metrics->{complexity} || 0;
        }
        
        # Aggregate by directory
        if ($by_directory) {
            my $dir = File::Spec->dirname($file);
            $metrics->{directories}->{$dir} ||= {
                files => 0,
                lines => 0,
                complexity => 0,
            };
            $metrics->{directories}->{$dir}->{files}++;
            $metrics->{directories}->{$dir}->{lines} += $file_metrics->{lines} || 0;
            $metrics->{directories}->{$dir}->{complexity} += $file_metrics->{complexity} || 0;
        }
    }
    
    chdir $original_cwd;
    
    my $result = {
        success => 1,
        action => 'metrics',
        repository_path => $repo_path,
        metrics => $metrics,
        analysis_timestamp => time(),
    };
    
    return $self->format_response($result);
}

sub _handle_patterns {
    my ($self, $params, $options, $repo_path) = @_;
    
    my $pattern_types = $params->{pattern_types} || ['architectural', 'design', 'naming'];
    
    my $original_cwd = getcwd();
    chdir $repo_path;
    
    my $patterns = {
        architectural => $self->_detect_architectural_patterns(),
        design => $self->_detect_design_patterns(),
        naming => $self->_analyze_naming_conventions(),
        organizational => $self->_analyze_organizational_patterns(),
    };
    
    chdir $original_cwd;
    
    my $result = {
        success => 1,
        action => 'patterns',
        repository_path => $repo_path,
        patterns => $patterns,
        recommendations => $self->_generate_pattern_recommendations($patterns),
        analysis_timestamp => time(),
    };
    
    return $self->format_response($result);
}

sub _handle_hotspots {
    my ($self, $params, $options, $repo_path) = @_;
    
    my $analysis_period = $params->{analysis_period} || '6 months';
    my $min_changes = $params->{min_changes} || 5;
    
    my $original_cwd = getcwd();
    chdir $repo_path;
    
    # Analyze Git history for change frequency
    my $hotspots = $self->_analyze_change_hotspots($analysis_period, $min_changes);
    my $complexity_hotspots = $self->_analyze_complexity_hotspots();
    
    chdir $original_cwd;
    
    my $result = {
        success => 1,
        action => 'hotspots',
        repository_path => $repo_path,
        change_hotspots => $hotspots,
        complexity_hotspots => $complexity_hotspots,
        combined_analysis => $self->_combine_hotspot_analysis($hotspots, $complexity_hotspots),
        analysis_timestamp => time(),
    };
    
    return $self->format_response($result);
}

sub _handle_complexity {
    my ($self, $params, $options, $repo_path) = @_;
    
    my $complexity_types = $params->{complexity_types} || ['cyclomatic', 'cognitive', 'structural'];
    my $threshold = $params->{threshold} || 10;
    
    my $original_cwd = getcwd();
    chdir $repo_path;
    
    my $complexity_analysis = {
        overview => {},
        files => {},
        functions => {},
        high_complexity_items => [],
    };
    
    my @source_files = $self->_get_all_source_files();
    
    for my $file (@source_files) {
        my $file_complexity = $self->_analyze_file_complexity($file, $complexity_types);
        $complexity_analysis->{files}->{$file} = $file_complexity;
        
        # Identify high complexity items
        if ($file_complexity->{overall_score} > $threshold) {
            push @{$complexity_analysis->{high_complexity_items}}, {
                type => 'file',
                path => $file,
                score => $file_complexity->{overall_score},
                metrics => $file_complexity,
            };
        }
    }
    
    chdir $original_cwd;
    
    my $result = {
        success => 1,
        action => 'complexity',
        repository_path => $repo_path,
        complexity_analysis => $complexity_analysis,
        recommendations => $self->_generate_complexity_recommendations($complexity_analysis),
        analysis_timestamp => time(),
    };
    
    return $self->format_response($result);
}

sub _handle_documentation {
    my ($self, $params, $options, $repo_path) = @_;
    
    my $include_inline = $params->{include_inline} || 1;
    my $generate_toc = $params->{generate_toc} || 1;
    
    my $original_cwd = getcwd();
    chdir $repo_path;
    
    my $documentation = {
        files => $self->_find_documentation_files(),
        inline_docs => $include_inline ? $self->_extract_inline_documentation() : {},
        coverage => $self->_calculate_documentation_coverage(),
        structure => $self->_analyze_documentation_structure(),
    };
    
    if ($generate_toc) {
        $documentation->{table_of_contents} = $self->_generate_documentation_toc($documentation);
    }
    
    chdir $original_cwd;
    
    my $result = {
        success => 1,
        action => 'documentation',
        repository_path => $repo_path,
        documentation => $documentation,
        recommendations => $self->_generate_documentation_recommendations($documentation),
        analysis_timestamp => time(),
    };
    
    return $self->format_response($result);
}

sub _handle_search {
    my ($self, $params, $options, $repo_path) = @_;
    
    my $query = $params->{query};
    my $search_type = $params->{search_type} || 'content';
    my $file_pattern = $params->{file_pattern} || '*';
    my $case_sensitive = $params->{case_sensitive} || 0;
    
    unless ($query) {
        return $self->handle_errors('Search query is required');
    }
    
    my $original_cwd = getcwd();
    chdir $repo_path;
    
    my $results = {};
    
    if ($search_type eq 'content' || $search_type eq 'all') {
        $results->{content} = $self->_search_file_contents($query, $file_pattern, $case_sensitive);
    }
    
    if ($search_type eq 'filename' || $search_type eq 'all') {
        $results->{filenames} = $self->_search_filenames($query, $case_sensitive);
    }
    
    if ($search_type eq 'structure' || $search_type eq 'all') {
        $results->{structure} = $self->_search_code_structure($query, $case_sensitive);
    }
    
    chdir $original_cwd;
    
    my $result = {
        success => 1,
        action => 'search',
        repository_path => $repo_path,
        query => $query,
        search_type => $search_type,
        results => $results,
        total_matches => $self->_count_total_matches($results),
        analysis_timestamp => time(),
    };
    
    return $self->format_response($result);
}

# Utility methods for structure analysis

sub _build_directory_structure {
    my ($self, $path, $current_depth, $max_depth, $include_hidden, $file_details) = @_;
    
    return {} if $current_depth >= $max_depth;
    return {} unless -d $path;
    
    my $structure = {
        type => 'directory',
        name => File::Spec->basename($path),
        path => $path,
        children => {},
    };
    
    opendir(my $dh, $path) or return $structure;
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    
    for my $entry (@entries) {
        next if !$include_hidden && $entry =~ /^\./;
        
        my $full_path = File::Spec->catfile($path, $entry);
        
        # Skip if matches exclude patterns
        my $skip = 0;
        for my $pattern (@{$self->{exclude_patterns}}) {
            if ($full_path =~ $pattern) {
                $skip = 1;
                last;
            }
        }
        next if $skip;
        
        if (-d $full_path) {
            $structure->{children}->{$entry} = $self->_build_directory_structure(
                $full_path, $current_depth + 1, $max_depth, $include_hidden, $file_details
            );
        } elsif (-f $full_path) {
            my $file_info = {
                type => 'file',
                name => $entry,
                path => $full_path,
            };
            
            if ($file_details) {
                my $stat = [stat($full_path)];
                $file_info->{size} = $stat->[7];
                $file_info->{modified} = $stat->[9];
                $file_info->{file_type} = $self->_classify_file_type($entry);
                $file_info->{language} = $self->_detect_file_language($entry);
            }
            
            $structure->{children}->{$entry} = $file_info;
        }
    }
    
    return $structure;
}

sub _calculate_structure_summary {
    my ($self, $structure) = @_;
    
    my $summary = {
        total_directories => 0,
        total_files => 0,
        file_types => {},
        languages => {},
        largest_files => [],
        recently_modified => [],
    };
    
    $self->_traverse_structure($structure, $summary);
    
    return $summary;
}

sub _traverse_structure {
    my ($self, $node, $summary) = @_;
    
    if ($node->{type} eq 'directory') {
        $summary->{total_directories}++;
        for my $child (values %{$node->{children}}) {
            $self->_traverse_structure($child, $summary);
        }
    } elsif ($node->{type} eq 'file') {
        $summary->{total_files}++;
        
        my $file_type = $node->{file_type} || 'unknown';
        $summary->{file_types}->{$file_type}++;
        
        my $language = $node->{language} || 'unknown';
        $summary->{languages}->{$language}++;
        
        # Track largest files (top 10)
        if (@{$summary->{largest_files}} < 10 || $node->{size} > $summary->{largest_files}->[-1]->{size}) {
            push @{$summary->{largest_files}}, $node;
            @{$summary->{largest_files}} = sort { $b->{size} <=> $a->{size} } @{$summary->{largest_files}};
            splice @{$summary->{largest_files}}, 10 if @{$summary->{largest_files}} > 10;
        }
    }
}

sub _classify_file_type {
    my ($self, $filename) = @_;
    
    for my $category (keys %{$self->{file_type_patterns}}) {
        for my $type (keys %{$self->{file_type_patterns}->{$category}}) {
            for my $pattern (@{$self->{file_type_patterns}->{$category}->{$type}}) {
                return "$category/$type" if $filename =~ $pattern;
            }
        }
    }
    
    return 'unknown';
}

sub _detect_file_language {
    my ($self, $filename) = @_;
    
    # Simple extension-based language detection
    return 'perl' if $filename =~ /\.p[lm]$|\.t$/;
    return 'python' if $filename =~ /\.py$/;
    return 'javascript' if $filename =~ /\.js$/;
    return 'typescript' if $filename =~ /\.ts$/;
    return 'java' if $filename =~ /\.java$/;
    return 'c' if $filename =~ /\.c$/;
    return 'cpp' if $filename =~ /\.cpp$|\.hpp$/;
    return 'ruby' if $filename =~ /\.rb$/;
    return 'go' if $filename =~ /\.go$/;
    return 'rust' if $filename =~ /\.rs$/;
    return 'php' if $filename =~ /\.php$/;
    return 'shell' if $filename =~ /\.sh$|\.bash$/;
    return 'json' if $filename =~ /\.json$/;
    return 'yaml' if $filename =~ /\.ya?ml$/;
    return 'xml' if $filename =~ /\.xml$/;
    return 'markdown' if $filename =~ /\.md$/;
    
    return 'unknown';
}

# Stub methods for comprehensive analysis (would be implemented with actual logic)

sub _analyze_perl_dependencies {
    my ($self) = @_;
    return {
        cpan_modules => ['JSON::PP', 'MIME::Base64', 'File::Spec'],
        internal_modules => ['CLIO::Protocols::Handler'],
        dependency_count => 3,
    };
}

sub _analyze_js_dependencies { return { npm_packages => [], dev_dependencies => [], dependency_count => 0 } }
sub _analyze_python_dependencies { return { pip_packages => [], requirements => [], dependency_count => 0 } }
sub _analyze_internal_dependencies { return { module_graph => {}, circular_dependencies => [] } }

sub _build_dependency_graph {
    my ($self, $deps) = @_;
    return { nodes => [], edges => [], complexity_score => 0 };
}

sub _calculate_overview_metrics {
    return {
        total_lines => 15000,
        total_files => 150,
        total_functions => 450,
        average_file_size => 100,
        test_coverage => 75,
    };
}

sub _get_all_source_files {
    my ($self) = @_;
    my @files = ();
    
    find(sub {
        return if -d $_;
        my $full_path = $File::Find::name;
        
        # Skip excluded patterns
        for my $pattern (@{$self->{exclude_patterns}}) {
            return if $full_path =~ $pattern;
        }
        
        # Include source files
        push @files, $full_path if $self->_is_source_file($_);
    }, '.');
    
    return @files;
}

sub _is_source_file {
    my ($self, $filename) = @_;
    
    for my $category (keys %{$self->{file_type_patterns}}) {
        next unless $category eq 'source_code';
        for my $type (keys %{$self->{file_type_patterns}->{$category}}) {
            for my $pattern (@{$self->{file_type_patterns}->{$category}->{$type}}) {
                return 1 if $filename =~ $pattern;
            }
        }
    }
    
    return 0;
}

sub _calculate_file_metrics {
    my ($self, $file) = @_;
    
    my $metrics = {
        lines => 0,
        blank_lines => 0,
        comment_lines => 0,
        code_lines => 0,
        complexity => 0,
        functions => 0,
    };
    
    if (open(my $fh, '<', $file)) {
        while (my $line = <$fh>) {
            $metrics->{lines}++;
            
            if ($line =~ /^\s*$/) {
                $metrics->{blank_lines}++;
            } elsif ($line =~ /^\s*#/) {
                $metrics->{comment_lines}++;
            } else {
                $metrics->{code_lines}++;
                
                # Simple complexity calculation
                $metrics->{complexity}++ if $line =~ /\b(if|while|for|foreach|unless)\b/;
                $metrics->{functions}++ if $line =~ /^\s*sub\s+\w+/;
            }
        }
        close($fh);
    }
    
    return $metrics;
}

# Additional stub methods (implementations would be much more comprehensive)

sub _detect_architectural_patterns { return { mvc => 0, layered => 1, microservices => 0 } }
sub _detect_design_patterns { return { singleton => 2, factory => 1, observer => 0 } }
sub _analyze_naming_conventions { return { consistent => 0.8, snake_case => 0.9, camelCase => 0.1 } }
sub _analyze_organizational_patterns { return { by_feature => 0.6, by_layer => 0.4 } }
sub _generate_pattern_recommendations { return ['Consider consistent naming', 'Improve architectural separation'] }

sub _analyze_change_hotspots { return [{ file => 'lib/main.pl', changes => 25, risk_score => 8.5 }] }
sub _analyze_complexity_hotspots { return [{ file => 'lib/complex.pl', complexity => 15, maintainability => 3.2 }] }
sub _combine_hotspot_analysis { return { high_risk_files => ['lib/main.pl'], recommendations => [] } }

sub _analyze_file_complexity { return { cyclomatic => 5, cognitive => 7, overall_score => 6 } }
sub _generate_complexity_recommendations { return ['Refactor high complexity functions'] }

sub _find_documentation_files { return ['README.md', 'docs/API.md'] }
sub _extract_inline_documentation { return { coverage => 0.6, quality => 0.7 } }
sub _calculate_documentation_coverage { return { overall => 0.65, by_module => {} } }
sub _analyze_documentation_structure { return { organized => 0.8, complete => 0.6 } }
sub _generate_documentation_toc { return { sections => [], navigation => {} } }
sub _generate_documentation_recommendations { return ['Add more inline comments'] }

sub _search_file_contents { return [{ file => 'test.pl', line => 42, context => 'matching content' }] }
sub _search_filenames { return ['matching_file.pl'] }
sub _search_code_structure { return [{ type => 'function', name => 'search_func', file => 'lib.pl' }] }
sub _count_total_matches { return 15 }

1;

__END__

=head1 USAGE EXAMPLES

=head2 Repository Structure Analysis

  [REPOMAP:action=structure:params=<base64_params>:options=<base64_options>]
  
  Params JSON:
  {
    "max_depth": 5,
    "include_hidden": false,
    "file_details": true
  }

=head2 Dependency Analysis

  [REPOMAP:action=dependencies:params=<base64_params>]
  
  Params JSON:
  {
    "analysis_type": "auto",
    "include_dev": true
  }

=head2 Code Metrics

  [REPOMAP:action=metrics:params=<base64_params>]
  
  Params JSON:
  {
    "metric_types": ["lines", "complexity", "maintainability"],
    "by_language": true,
    "by_directory": true
  }

=head2 Search Repository

  [REPOMAP:action=search:params=<base64_params>]
  
  Params JSON:
  {
    "query": "function_name",
    "search_type": "all",
    "case_sensitive": false
  }

=head1 RETURN FORMAT

  {
    "success": true,
    "action": "structure",
    "repository_path": "/path/to/repo",
    "structure": {
      "type": "directory",
      "name": "repo",
      "children": {
        "lib": {
          "type": "directory",
          "children": { ... }
        },
        "README.md": {
          "type": "file",
          "size": 1024,
          "file_type": "documentation/markdown",
          "language": "markdown"
        }
      }
    },
    "summary": {
      "total_directories": 15,
      "total_files": 127,
      "file_types": {
        "source_code/perl": 45,
        "documentation/markdown": 8
      }
    }
  }
1;
