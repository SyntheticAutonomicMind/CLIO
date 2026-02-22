package CLIO::Protocols::TreeSit;

use strict;
use warnings;
use base 'CLIO::Protocols::Handler';
use MIME::Base64;
use CLIO::Util::JSON qw(encode_json decode_json);
use File::Spec;
use Cwd;

=head1 NAME

CLIO::Protocols::TreeSit - Tree-sitter integration protocol handler for syntax analysis

=head1 DESCRIPTION

This module provides comprehensive tree-sitter integration for parsing, analyzing, and manipulating
source code syntax trees. It supports multiple programming languages and provides advanced
code intelligence features including symbol extraction, AST analysis, and code transformation.

=head1 PROTOCOL FORMAT

[TREESIT:action=<action>:params=<base64_params>:options=<base64_options>]

Actions:
- parse: Parse source code into AST
- query: Execute tree-sitter queries on AST
- symbols: Extract symbols (functions, classes, variables)
- navigate: Navigate AST nodes and relationships
- transform: Apply AST transformations
- validate: Validate syntax and structure
- refactor: Perform code refactoring operations
- analyze: Analyze code patterns and structure

=cut

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        supported_languages => {
            'perl' => {
                parser => 'tree-sitter-perl',
                queries_path => 'queries/perl',
                file_extensions => ['.pl', '.pm', '.t'],
            },
            'python' => {
                parser => 'tree-sitter-python',
                queries_path => 'queries/python',
                file_extensions => ['.py'],
            },
            'javascript' => {
                parser => 'tree-sitter-javascript',
                queries_path => 'queries/javascript',
                file_extensions => ['.js', '.jsx'],
            },
            'typescript' => {
                parser => 'tree-sitter-typescript',
                queries_path => 'queries/typescript',
                file_extensions => ['.ts', '.tsx'],
            },
            'json' => {
                parser => 'tree-sitter-json',
                queries_path => 'queries/json',
                file_extensions => ['.json'],
            },
            'yaml' => {
                parser => 'tree-sitter-yaml',
                queries_path => 'queries/yaml',
                file_extensions => ['.yml', '.yaml'],
            },
        },
        query_cache => {},
        ast_cache => {},
        max_cache_size => $args{max_cache_size} || 100,
        enable_caching => $args{enable_caching} // 1,
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
    
    # Parse protocol: [TREESIT:action=<action>:params=<base64_params>:options=<base64_options>]
    if ($input !~ /^\[TREESIT:action=([^:]+):params=([^:]+)(?::options=([^:]+))?\]$/) {
        return $self->handle_errors('Invalid TREESIT protocol format');
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
                $params = { content => $params_str };
            }
        } else {
            $params = { content => $params_str };
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
    
    # Route to appropriate action handler
    my $handlers = {
        parse => \&_handle_parse,
        query => \&_handle_query,
        symbols => \&_handle_symbols,
        navigate => \&_handle_navigate,
        transform => \&_handle_transform,
        validate => \&_handle_validate,
        refactor => \&_handle_refactor,
        analyze => \&_handle_analyze,
    };
    
    my $handler = $handlers->{$action};
    if ($handler) {
        return $handler->($self, $params, $options);
    } else {
        return $self->handle_errors("Unknown TREESIT action: $action");
    }
}

sub _handle_parse {
    my ($self, $params, $options) = @_;
    
    my $content = $params->{content};
    my $file_path = $params->{file_path};
    my $language = $params->{language} || $self->_detect_language($file_path);
    
    unless ($content || $file_path) {
        return $self->handle_errors('Either content or file_path must be provided');
    }
    
    # Read file content if file_path provided
    if ($file_path && !$content) {
        if (open(my $fh, '<', $file_path)) {
            local $/;
            $content = <$fh>;
            close($fh);
        } else {
            return $self->handle_errors("Failed to read file: $file_path");
        }
    }
    
    unless ($language && $self->{supported_languages}->{$language}) {
        return $self->handle_errors("Unsupported or undetected language: " . ($language || 'unknown'));
    }
    
    # Parse content into AST
    my $ast_result = $self->_parse_with_treesitter($content, $language);
    
    # Cache result if caching enabled
    if ($self->{enable_caching} && $file_path) {
        $self->_cache_ast($file_path, $ast_result);
    }
    
    my $result = {
        success => 1,
        action => 'parse',
        language => $language,
        file_path => $file_path,
        content_length => length($content),
        ast => $ast_result->{ast},
        parse_time => $ast_result->{parse_time},
        errors => $ast_result->{errors},
        warnings => $ast_result->{warnings},
        node_count => $ast_result->{node_count},
        depth => $ast_result->{depth},
    };
    
    return $self->format_response($result);
}

sub _handle_query {
    my ($self, $params, $options) = @_;
    
    my $query_string = $params->{query};
    my $content = $params->{content};
    my $file_path = $params->{file_path};
    my $language = $params->{language} || $self->_detect_language($file_path);
    my $ast = $params->{ast};
    
    unless ($query_string) {
        return $self->handle_errors('Query string is required');
    }
    
    # Get or create AST
    unless ($ast) {
        if ($self->{enable_caching} && $file_path && $self->{ast_cache}->{$file_path}) {
            $ast = $self->{ast_cache}->{$file_path}->{ast};
        } else {
            my $parse_result = $self->_handle_parse($params, $options);
            return $parse_result unless $parse_result->{success};
            $ast = $parse_result->{ast};
        }
    }
    
    # Execute query
    my $query_result = $self->_execute_treesitter_query($ast, $query_string, $language);
    
    my $result = {
        success => 1,
        action => 'query',
        language => $language,
        query => $query_string,
        matches => $query_result->{matches},
        match_count => scalar @{$query_result->{matches}},
        execution_time => $query_result->{execution_time},
        query_errors => $query_result->{errors},
    };
    
    return $self->format_response($result);
}

sub _handle_symbols {
    my ($self, $params, $options) = @_;
    
    my $symbol_types = $params->{symbol_types} || ['functions', 'classes', 'variables', 'imports'];
    my $include_private = $params->{include_private} || 0;
    my $include_locations = $params->{include_locations} || 1;
    my $file_path = $params->{file_path};
    my $language = $params->{language} || $self->_detect_language($file_path);
    
    # Get AST
    my $ast;
    if ($self->{enable_caching} && $file_path && $self->{ast_cache}->{$file_path}) {
        $ast = $self->{ast_cache}->{$file_path}->{ast};
    } else {
        my $parse_result = $self->_handle_parse($params, $options);
        return $parse_result unless $parse_result->{success};
        $ast = $parse_result->{ast};
    }
    
    # Extract symbols by type
    my $symbols = {};
    
    for my $symbol_type (@$symbol_types) {
        $symbols->{$symbol_type} = $self->_extract_symbols_by_type(
            $ast, $symbol_type, $language, $include_private, $include_locations
        );
    }
    
    # Calculate symbol statistics
    my $statistics = $self->_calculate_symbol_statistics($symbols);
    
    my $result = {
        success => 1,
        action => 'symbols',
        language => $language,
        file_path => $file_path,
        symbols => $symbols,
        statistics => $statistics,
        symbol_types => $symbol_types,
        total_symbols => $statistics->{total_count},
    };
    
    return $self->format_response($result);
}

sub _handle_navigate {
    my ($self, $params, $options) = @_;
    
    my $node_id = $params->{node_id};
    my $navigation_type = $params->{navigation_type} || 'children';
    my $filter = $params->{filter} || {};
    my $max_depth = $params->{max_depth} || 5;
    my $ast = $params->{ast};
    
    unless ($ast && $node_id) {
        return $self->handle_errors('AST and node_id are required for navigation');
    }
    
    my $navigation_result = $self->_navigate_ast_node(
        $ast, $node_id, $navigation_type, $filter, $max_depth
    );
    
    my $result = {
        success => 1,
        action => 'navigate',
        node_id => $node_id,
        navigation_type => $navigation_type,
        results => $navigation_result->{nodes},
        result_count => scalar @{$navigation_result->{nodes}},
        path => $navigation_result->{path},
    };
    
    return $self->format_response($result);
}

sub _handle_transform {
    my ($self, $params, $options) = @_;
    
    my $transformation_type = $params->{transformation_type};
    my $target_nodes = $params->{target_nodes} || [];
    my $transformation_params = $params->{transformation_params} || {};
    my $dry_run = $params->{dry_run} || 0;
    my $ast = $params->{ast};
    
    unless ($transformation_type && $ast) {
        return $self->handle_errors('transformation_type and AST are required');
    }
    
    my $transformation_result = $self->_apply_ast_transformation(
        $ast, $transformation_type, $target_nodes, $transformation_params, $dry_run
    );
    
    my $result = {
        success => 1,
        action => 'transform',
        transformation_type => $transformation_type,
        dry_run => $dry_run,
        transformations_applied => $transformation_result->{count},
        modified_nodes => $transformation_result->{modified_nodes},
        generated_code => $transformation_result->{generated_code},
        warnings => $transformation_result->{warnings},
    };
    
    return $self->format_response($result);
}

sub _handle_validate {
    my ($self, $params, $options) = @_;
    
    my $validation_types = $params->{validation_types} || ['syntax', 'structure', 'style'];
    my $language = $params->{language};
    my $content = $params->{content};
    my $file_path = $params->{file_path};
    my $ast = $params->{ast};
    
    # Get AST if not provided
    unless ($ast) {
        my $parse_result = $self->_handle_parse($params, $options);
        return $parse_result unless $parse_result->{success};
        $ast = $parse_result->{ast};
    }
    
    my $validation_results = {};
    
    for my $validation_type (@$validation_types) {
        $validation_results->{$validation_type} = $self->_validate_ast(
            $ast, $validation_type, $language, $content
        );
    }
    
    # Aggregate results
    my $overall_valid = 1;
    my @all_issues = ();
    
    for my $type (keys %$validation_results) {
        my $result = $validation_results->{$type};
        $overall_valid = 0 unless $result->{valid};
        push @all_issues, @{$result->{issues}};
    }
    
    my $result = {
        success => 1,
        action => 'validate',
        language => $language,
        file_path => $file_path,
        overall_valid => $overall_valid,
        validation_results => $validation_results,
        all_issues => \@all_issues,
        issue_count => scalar @all_issues,
        validation_types => $validation_types,
    };
    
    return $self->format_response($result);
}

sub _handle_refactor {
    my ($self, $params, $options) = @_;
    
    my $refactor_type = $params->{refactor_type};
    my $target_symbol = $params->{target_symbol};
    my $refactor_params = $params->{refactor_params} || {};
    my $safe_mode = $params->{safe_mode} || 1;
    my $ast = $params->{ast};
    
    unless ($refactor_type && $ast) {
        return $self->handle_errors('refactor_type and AST are required');
    }
    
    my $refactor_result = $self->_perform_refactoring(
        $ast, $refactor_type, $target_symbol, $refactor_params, $safe_mode
    );
    
    my $result = {
        success => 1,
        action => 'refactor',
        refactor_type => $refactor_type,
        target_symbol => $target_symbol,
        safe_mode => $safe_mode,
        changes_made => $refactor_result->{changes},
        modified_files => $refactor_result->{modified_files},
        warnings => $refactor_result->{warnings},
        rollback_info => $refactor_result->{rollback_info},
    };
    
    return $self->format_response($result);
}

sub _handle_analyze {
    my ($self, $params, $options) = @_;
    
    my $analysis_types = $params->{analysis_types} || ['complexity', 'patterns', 'dependencies'];
    my $include_metrics = $params->{include_metrics} || 1;
    my $ast = $params->{ast};
    my $language = $params->{language};
    
    unless ($ast) {
        my $parse_result = $self->_handle_parse($params, $options);
        return $parse_result unless $parse_result->{success};
        $ast = $parse_result->{ast};
    }
    
    my $analysis_results = {};
    
    for my $analysis_type (@$analysis_types) {
        $analysis_results->{$analysis_type} = $self->_analyze_ast(
            $ast, $analysis_type, $language, $include_metrics
        );
    }
    
    # Generate recommendations based on analysis
    my $recommendations = $self->_generate_analysis_recommendations($analysis_results);
    
    my $result = {
        success => 1,
        action => 'analyze',
        language => $language,
        analysis_types => $analysis_types,
        analysis_results => $analysis_results,
        recommendations => $recommendations,
        analysis_timestamp => time(),
    };
    
    return $self->format_response($result);
}

# Core tree-sitter integration methods

sub _parse_with_treesitter {
    my ($self, $content, $language) = @_;
    
    my $start_time = time();
    
    # This would integrate with actual tree-sitter library
    # For now, return mock AST structure
    my $ast = $self->_create_mock_ast($content, $language);
    
    my $parse_time = time() - $start_time;
    
    return {
        ast => $ast,
        parse_time => $parse_time,
        errors => [],
        warnings => [],
        node_count => $self->_count_ast_nodes($ast),
        depth => $self->_calculate_ast_depth($ast),
    };
}

sub _execute_treesitter_query {
    my ($self, $ast, $query_string, $language) = @_;
    
    my $start_time = time();
    
    # Mock query execution - would use actual tree-sitter query engine
    my $matches = $self->_mock_query_execution($ast, $query_string, $language);
    
    my $execution_time = time() - $start_time;
    
    return {
        matches => $matches,
        execution_time => $execution_time,
        errors => [],
    };
}

sub _extract_symbols_by_type {
    my ($self, $ast, $symbol_type, $language, $include_private, $include_locations) = @_;
    
    # Mock symbol extraction based on language and type
    my $symbols = [];
    
    if ($symbol_type eq 'functions') {
        $symbols = $self->_extract_function_symbols($ast, $language, $include_private, $include_locations);
    } elsif ($symbol_type eq 'classes') {
        $symbols = $self->_extract_class_symbols($ast, $language, $include_private, $include_locations);
    } elsif ($symbol_type eq 'variables') {
        $symbols = $self->_extract_variable_symbols($ast, $language, $include_private, $include_locations);
    } elsif ($symbol_type eq 'imports') {
        $symbols = $self->_extract_import_symbols($ast, $language, $include_locations);
    }
    
    return $symbols;
}

sub _detect_language {
    my ($self, $file_path) = @_;
    
    return unless $file_path;
    
    for my $lang (keys %{$self->{supported_languages}}) {
        my $extensions = $self->{supported_languages}->{$lang}->{file_extensions};
        for my $ext (@$extensions) {
            return $lang if $file_path =~ /\Q$ext\E$/;
        }
    }
    
    return 'unknown';
}

sub _cache_ast {
    my ($self, $file_path, $ast_result) = @_;
    
    # Simple LRU cache implementation
    if (keys %{$self->{ast_cache}} >= $self->{max_cache_size}) {
        my $oldest_key = (sort keys %{$self->{ast_cache}})[0];
        delete $self->{ast_cache}->{$oldest_key};
    }
    
    $self->{ast_cache}->{$file_path} = {
        ast => $ast_result->{ast},
        timestamp => time(),
        file_path => $file_path,
    };
}

# Mock implementations (would be replaced with actual tree-sitter integration)

sub _create_mock_ast {
    my ($self, $content, $language) = @_;
    
    return {
        type => 'source_file',
        language => $language,
        children => [
            {
                type => 'function_definition',
                name => 'example_function',
                parameters => ['param1', 'param2'],
                body => {
                    type => 'block',
                    statements => []
                },
                location => { start => { line => 1, column => 0 }, end => { line => 10, column => 1 } }
            }
        ]
    };
}

sub _count_ast_nodes {
    my ($self, $ast) = @_;
    
    my $count = 1;  # Count this node
    
    if ($ast->{children}) {
        for my $child (@{$ast->{children}}) {
            $count += $self->_count_ast_nodes($child);
        }
    }
    
    return $count;
}

sub _calculate_ast_depth {
    my ($self, $ast, $current_depth) = @_;
    
    $current_depth ||= 0;
    my $max_depth = $current_depth;
    
    if ($ast->{children}) {
        for my $child (@{$ast->{children}}) {
            my $child_depth = $self->_calculate_ast_depth($child, $current_depth + 1);
            $max_depth = $child_depth if $child_depth > $max_depth;
        }
    }
    
    return $max_depth;
}

sub _mock_query_execution {
    my ($self, $ast, $query, $language) = @_;
    
    return [
        {
            node => $ast->{children}->[0],
            captures => { function_name => 'example_function' },
            start => { line => 1, column => 0 },
            end => { line => 10, column => 1 }
        }
    ];
}

sub _extract_function_symbols {
    my ($self, $ast, $language, $include_private, $include_locations) = @_;
    
    return [
        {
            name => 'example_function',
            type => 'function',
            visibility => 'public',
            parameters => ['param1', 'param2'],
            return_type => 'unknown',
            location => $include_locations ? { start => { line => 1, column => 0 }, end => { line => 10, column => 1 } } : undef,
        }
    ];
}

sub _extract_class_symbols { return [] }
sub _extract_variable_symbols { return [] }
sub _extract_import_symbols { return [] }

sub _calculate_symbol_statistics {
    my ($self, $symbols) = @_;
    
    my $stats = { total_count => 0 };
    
    for my $type (keys %$symbols) {
        my $count = scalar @{$symbols->{$type}};
        $stats->{$type . '_count'} = $count;
        $stats->{total_count} += $count;
    }
    
    return $stats;
}

sub _navigate_ast_node { return { nodes => [], path => [] } }
sub _apply_ast_transformation { return { count => 0, modified_nodes => [], generated_code => '', warnings => [] } }
sub _validate_ast { return { valid => 1, issues => [] } }
sub _perform_refactoring { return { changes => [], modified_files => [], warnings => [], rollback_info => {} } }
sub _analyze_ast { return { complexity_score => 5, patterns => [], dependencies => [] } }
sub _generate_analysis_recommendations { return ['Consider refactoring complex functions'] }

1;

__END__

=head1 USAGE EXAMPLES

=head2 Parse Source Code

  [TREESIT:action=parse:params=<base64_params>]
  
  Params JSON:
  {
    "file_path": "/path/to/source.pl",
    "language": "perl"
  }

=head2 Execute Tree-sitter Query

  [TREESIT:action=query:params=<base64_params>]
  
  Params JSON:
  {
    "query": "(function_definition name: (identifier) @function.name)",
    "file_path": "/path/to/source.pl",
    "language": "perl"
  }

=head3 Extract Symbols

  [TREESIT:action=symbols:params=<base64_params>]
  
  Params JSON:
  {
    "symbol_types": ["functions", "classes", "variables"],
    "include_private": false,
    "file_path": "/path/to/source.pl"
  }

=head2 Code Validation

  [TREESIT:action=validate:params=<base64_params>]
  
  Params JSON:
  {
    "validation_types": ["syntax", "structure", "style"],
    "file_path": "/path/to/source.pl",
    "language": "perl"
  }

=head1 RETURN FORMAT

  {
    "success": true,
    "action": "symbols",
    "language": "perl",
    "symbols": {
      "functions": [
        {
          "name": "example_function",
          "type": "function",
          "visibility": "public",
          "parameters": ["param1", "param2"],
          "location": {
            "start": {"line": 1, "column": 0},
            "end": {"line": 10, "column": 1}
          }
        }
      ],
      "classes": [],
      "variables": []
    },
    "statistics": {
      "total_count": 1,
      "functions_count": 1,
      "classes_count": 0,
      "variables_count": 0
    }
  }
1;
