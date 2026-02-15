package CLIO::Code::Relations;

use strict;
use warnings;
use JSON::PP;

=head1 NAME

CLIO::Code::Relations - Code relationship mapping and dependency analysis

=head1 SYNOPSIS

    use CLIO::Code::Relations;
    
    my $relations = CLIO::Code::Relations->new(debug => 1);
    $relations->analyze_dependencies($filepath);
    my $deps = $relations->get_dependencies($symbol);

=head1 DESCRIPTION

This module analyzes code relationships, dependencies, and usage patterns
to build comprehensive understanding of code structure and interactions.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} || 0,
        dependencies => {},   # Symbol -> [dependencies]
        dependents => {},     # Symbol -> [dependents] 
        call_graph => {},     # Function call relationships
        inheritance => {},    # Class inheritance relationships
        file_deps => {},      # File-level dependencies
        symbol_manager => undef
    };
    
    return bless $self, $class;
}

=head2 set_symbol_manager($symbol_mgr)

Set the symbol manager instance.

=cut

sub set_symbol_manager {
    my ($self, $symbol_mgr) = @_;
    $self->{symbol_manager} = $symbol_mgr;
    warn "[DEBUG Relations] Symbol manager set\n" if $self->{debug};
}

=head2 analyze_dependencies($filepath)

Analyze dependencies in a file.

=cut

sub analyze_dependencies {
    my ($self, $filepath) = @_;
    
    return 0 unless -f $filepath;
    
    warn "[DEBUG Relations] Analyzing dependencies in: $filepath\n" if $self->{debug};
    
    open my $fh, '<', $filepath or return 0;
    my $content = do { local $/; <$fh> };
    close $fh;
    
    my @lines = split /\n/, $content;
    my $line_num = 0;
    my $current_package = '';
    my $current_sub = '';
    
    for my $line (@lines) {
        $line_num++;
        chomp $line;
        next if $line =~ /^\s*$/ || $line =~ /^\s*#/;
        
        # Track current context
        if ($line =~ /^package\s+([A-Za-z0-9:_]+)/) {
            $current_package = $1;
        } elsif ($line =~ /^sub\s+([A-Za-z0-9_]+)/) {
            $current_sub = $1;
        }
        
        # Analyze different types of dependencies
        $self->_analyze_imports($line, $filepath, $line_num);
        $self->_analyze_function_calls($line, $filepath, $line_num, $current_package, $current_sub);
        $self->_analyze_variable_usage($line, $filepath, $line_num, $current_package);
        $self->_analyze_inheritance($line, $filepath, $line_num, $current_package);
    }
    
    warn "[DEBUG Relations] Completed dependency analysis for $filepath\n" if $self->{debug};
    return 1;
}

=head2 _analyze_imports($line, $filepath, $line_num)

Analyze import/use statements.

=cut

sub _analyze_imports {
    my ($self, $line, $filepath, $line_num) = @_;
    
    if ($line =~ /^use\s+([A-Za-z0-9:_]+)/) {
        my $module = $1;
        
        # Skip built-in modules
        return if $module =~ /^(strict|warnings|Carp|Data::Dumper|JSON|File::|POSIX)$/;
        
        $self->_add_dependency($filepath, $module, 'import', $line_num);
        $self->_add_file_dependency($filepath, $module);
    }
}

=head2 _analyze_function_calls($line, $filepath, $line_num, $package, $sub)

Analyze function calls and method invocations.

=cut

sub _analyze_function_calls {
    my ($self, $line, $filepath, $line_num, $package, $sub) = @_;
    
    return unless $sub;  # Only analyze within subroutines
    
    # Method calls: $obj->method()
    while ($line =~ /\$\w+->([A-Za-z0-9_]+)\s*\(/g) {
        my $method = $1;
        $self->_add_call_relationship("$package\::$sub", $method, $line_num);
    }
    
    # Direct function calls: function_name()
    while ($line =~ /([A-Za-z0-9_]+)\s*\(/g) {
        my $func = $1;
        next if $func =~ /^(if|while|for|foreach|unless|print|warn|die)$/;  # Skip keywords
        
        $self->_add_call_relationship("$package\::$sub", $func, $line_num);
    }
    
    # Package function calls: Package::function()
    while ($line =~ /([A-Za-z0-9:_]+)::([A-Za-z0-9_]+)\s*\(/g) {
        my ($pkg, $func) = ($1, $2);
        $self->_add_call_relationship("$package\::$sub", "$pkg\::$func", $line_num);
    }
}

=head2 _analyze_variable_usage($line, $filepath, $line_num, $package)

Analyze variable usage patterns.

=cut

sub _analyze_variable_usage {
    my ($self, $line, $filepath, $line_num, $package) = @_;
    
    # Global variables: $Package::variable
    while ($line =~ /\$([A-Za-z0-9:_]+::)([A-Za-z0-9_]+)/g) {
        my ($pkg, $var) = ($1, $2);
        $pkg =~ s/::$//;
        $self->_add_dependency($filepath, "$pkg\::\$$var", 'variable', $line_num);
    }
}

=head2 _analyze_inheritance($line, $filepath, $line_num, $package)

Analyze class inheritance relationships.

=cut

sub _analyze_inheritance {
    my ($self, $line, $filepath, $line_num, $package) = @_;
    
    # ISA inheritance: @ISA = qw(Parent::Class);
    if ($line =~ /\@ISA\s*=.*qw\s*\(\s*([^)]+)\s*\)/) {
        my $parents = $1;
        for my $parent (split /\s+/, $parents) {
            $self->_add_inheritance_relationship($package, $parent, $line_num);
        }
    }
    
    # use base inheritance: use base qw(Parent::Class);
    if ($line =~ /use\s+base\s+qw\s*\(\s*([^)]+)\s*\)/) {
        my $parents = $1;
        for my $parent (split /\s+/, $parents) {
            $self->_add_inheritance_relationship($package, $parent, $line_num);
        }
    }
}

=head2 _add_dependency($source, $target, $type, $line)

Add a dependency relationship.

=cut

sub _add_dependency {
    my ($self, $source, $target, $type, $line) = @_;
    
    $self->{dependencies}->{$source} ||= [];
    push @{$self->{dependencies}->{$source}}, {
        target => $target,
        type => $type,
        line => $line
    };
    
    $self->{dependents}->{$target} ||= [];
    push @{$self->{dependents}->{$target}}, {
        source => $source,
        type => $type,
        line => $line
    };
    
    warn "[DEBUG Relations] Added $type dependency: $source -> $target (line $line)\n" if $self->{debug};
}

=head2 _add_call_relationship($caller, $callee, $line)

Add a function call relationship.

=cut

sub _add_call_relationship {
    my ($self, $caller, $callee, $line) = @_;
    
    $self->{call_graph}->{$caller} ||= [];
    push @{$self->{call_graph}->{$caller}}, {
        callee => $callee,
        line => $line
    };
    
    warn "[DEBUG Relations] Added call: $caller -> $callee (line $line)\n" if $self->{debug};
}

=head2 _add_inheritance_relationship($child, $parent, $line)

Add an inheritance relationship.

=cut

sub _add_inheritance_relationship {
    my ($self, $child, $parent, $line) = @_;
    
    $self->{inheritance}->{$child} ||= [];
    push @{$self->{inheritance}->{$child}}, {
        parent => $parent,
        line => $line
    };
    
    warn "[DEBUG Relations] Added inheritance: $child extends $parent (line $line)\n" if $self->{debug};
}

=head2 _add_file_dependency($source_file, $target_module)

Add a file-level dependency.

=cut

sub _add_file_dependency {
    my ($self, $source_file, $target_module) = @_;
    
    $self->{file_deps}->{$source_file} ||= [];
    push @{$self->{file_deps}->{$source_file}}, $target_module;
}

=head2 get_dependencies($symbol)

Get all dependencies of a symbol.

=cut

sub get_dependencies {
    my ($self, $symbol) = @_;
    
    return $self->{dependencies}->{$symbol} || [];
}

=head2 get_dependents($symbol)

Get all symbols that depend on this symbol.

=cut

sub get_dependents {
    my ($self, $symbol) = @_;
    
    return $self->{dependents}->{$symbol} || [];
}

=head2 get_call_graph($function)

Get the call graph for a function.

=cut

sub get_call_graph {
    my ($self, $function) = @_;
    
    return $self->{call_graph}->{$function} || [];
}

=head2 get_inheritance_tree($class)

Get the inheritance tree for a class.

=cut

sub get_inheritance_tree {
    my ($self, $class) = @_;
    
    return $self->{inheritance}->{$class} || [];
}

=head2 find_circular_dependencies()

Find circular dependencies in the codebase.

=cut

sub find_circular_dependencies {
    my ($self) = @_;
    
    warn "[DEBUG Relations] Searching for circular dependencies\n" if $self->{debug};
    
    my @cycles;
    my %visited;
    my %in_path;
    
    for my $symbol (keys %{$self->{dependencies}}) {
        next if $visited{$symbol};
        
        my @path;
        my $cycle = $self->_dfs_cycle_detection($symbol, \%visited, \%in_path, \@path);
        push @cycles, $cycle if $cycle;
    }
    
    warn "[DEBUG Relations] Found ", scalar(@cycles), " circular dependencies\n" if $self->{debug};
    
    return \@cycles;
}

=head2 _dfs_cycle_detection($node, $visited, $in_path, $path)

DFS-based cycle detection.

=cut

sub _dfs_cycle_detection {
    my ($self, $node, $visited, $in_path, $path) = @_;
    
    return undef if $visited->{$node};
    
    $visited->{$node} = 1;
    $in_path->{$node} = 1;
    push @$path, $node;
    
    my $deps = $self->{dependencies}->{$node} || [];
    for my $dep (@$deps) {
        my $target = $dep->{target};
        
        if ($in_path->{$target}) {
            # Found cycle
            my $cycle_start = 0;
            for my $i (0..$#$path) {
                if ($path->[$i] eq $target) {
                    $cycle_start = $i;
                    last;
                }
            }
            return [@$path[$cycle_start..$#$path], $target];
        }
        
        my $cycle = $self->_dfs_cycle_detection($target, $visited, $in_path, $path);
        return $cycle if $cycle;
    }
    
    $in_path->{$node} = 0;
    pop @$path;
    return undef;
}

=head2 get_statistics()

Get relationship analysis statistics.

=cut

sub get_statistics {
    my ($self) = @_;
    
    return {
        total_dependencies => scalar(keys %{$self->{dependencies}}),
        total_dependents => scalar(keys %{$self->{dependents}}),
        total_calls => scalar(keys %{$self->{call_graph}}),
        total_inheritance => scalar(keys %{$self->{inheritance}}),
        file_dependencies => scalar(keys %{$self->{file_deps}})
    };
}

=head2 export_graph($format)

Export relationship graph in specified format.

=cut

sub export_graph {
    my ($self, $format) = @_;
    
    $format ||= 'json';
    
    if ($format eq 'json') {
        return JSON->new->pretty->encode({
            dependencies => $self->{dependencies},
            dependents => $self->{dependents},
            call_graph => $self->{call_graph},
            inheritance => $self->{inheritance},
            file_deps => $self->{file_deps}
        });
    } elsif ($format eq 'dot') {
        return $self->_export_dot_format();
    }
    
    return undef;
}

=head2 _export_dot_format()

Export in DOT format for graphviz.

=cut

sub _export_dot_format {
    my ($self) = @_;
    
    my $dot = "digraph CodeRelations {\n";
    $dot .= "  rankdir=LR;\n";
    $dot .= "  node [shape=box];\n\n";
    
    # Add dependencies
    for my $source (keys %{$self->{dependencies}}) {
        for my $dep (@{$self->{dependencies}->{$source}}) {
            my $target = $dep->{target};
            my $type = $dep->{type};
            $dot .= "  \"$source\" -> \"$target\" [label=\"$type\"];\n";
        }
    }
    
    $dot .= "}\n";
    return $dot;
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 COPYRIGHT

Copyright (c) 2025 CLIO Project. All rights reserved.

=cut

1;
