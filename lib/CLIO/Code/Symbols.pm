package CLIO::Code::Symbols;

use strict;
use warnings;
use JSON::PP;
use File::Basename;
use File::Spec;

=head1 NAME

CLIO::Code::Symbols - Symbol extraction and management system

=head1 SYNOPSIS

    use CLIO::Code::Symbols;
    
    my $symbol_manager = CLIO::Code::Symbols->new(debug => 1);
    $symbol_manager->index_file($filepath);
    my $symbols = $symbol_manager->find_symbols('function_name');

=head1 DESCRIPTION

This module manages symbol extraction, indexing, and lookup across codebases.
It integrates with the TreeSitter module to build comprehensive symbol databases.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} || 0,
        cache_dir => $args{cache_dir} || '/tmp/clio_symbols',
        symbol_index => {},  # In-memory symbol index
        file_index => {},    # Track indexed files
        tree_sitter => undef
    };
    
    # Create cache directory
    unless (-d $self->{cache_dir}) {
        mkdir $self->{cache_dir} or warn "[WARN Symbols] Cannot create cache dir: $!\n";
    }
    
    return bless $self, $class;
}

=head2 set_tree_sitter($ts_instance)

Set the TreeSitter instance to use for parsing.

=cut

sub set_tree_sitter {
    my ($self, $ts) = @_;
    $self->{tree_sitter} = $ts;
    warn "[DEBUG Symbols] TreeSitter instance set\n" if $self->{debug};
}

=head2 index_file($filepath)

Index symbols from a file.

=cut

sub index_file {
    my ($self, $filepath) = @_;
    
    return 0 unless -f $filepath;
    
    warn "[DEBUG Symbols] Indexing file: $filepath\n" if $self->{debug};
    
    # Use TreeSitter if available, otherwise fall back to basic parsing
    my $analysis;
    if ($self->{tree_sitter}) {
        $analysis = $self->{tree_sitter}->analyze_file($filepath);
    } else {
        $analysis = $self->_basic_file_analysis($filepath);
    }
    
    return 0 unless $analysis;
    
    # Index the symbols
    my $file_key = $self->_normalize_path($filepath);
    $self->{file_index}->{$file_key} = {
        filepath => $filepath,
        last_indexed => time(),
        symbol_count => scalar(@{$analysis->{symbols}})
    };
    
    # Add symbols to index
    for my $symbol (@{$analysis->{symbols}}) {
        my $key = $symbol->{name};
        
        $self->{symbol_index}->{$key} ||= [];
        push @{$self->{symbol_index}->{$key}}, {
            %$symbol,
            filepath => $filepath,
            file_key => $file_key
        };
    }
    
    warn "[DEBUG Symbols] Indexed ", scalar(@{$analysis->{symbols}}), " symbols from $filepath\n" if $self->{debug};
    
    # Cache the analysis
    $self->_cache_analysis($file_key, $analysis);
    
    return scalar(@{$analysis->{symbols}});
}

=head2 _basic_file_analysis($filepath)

Basic file analysis without TreeSitter.

=cut

sub _basic_file_analysis {
    my ($self, $filepath) = @_;
    
    open my $fh, '<', $filepath or return undef;
    my $content = do { local $/; <$fh> };
    close $fh;
    
    my $symbols = [];
    my @lines = split /\n/, $content;
    my $line_num = 0;
    
    for my $line (@lines) {
        $line_num++;
        chomp $line;
        next if $line =~ /^\s*$/ || $line =~ /^\s*#/;
        
        # Perl symbols
        if ($line =~ /^package\s+([A-Za-z0-9:_]+)/) {
            push @$symbols, {
                type => 'package',
                name => $1,
                line => $line_num,
                scope => 'global'
            };
        } elsif ($line =~ /^sub\s+([A-Za-z0-9_]+)/) {
            push @$symbols, {
                type => 'function',
                name => $1,
                line => $line_num,
                scope => 'package'
            };
        } elsif ($line =~ /^my\s+\$([A-Za-z0-9_]+)/) {
            push @$symbols, {
                type => 'variable',
                name => "\$$1",
                line => $line_num,
                scope => 'local'
            };
        }
    }
    
    return {
        filepath => $filepath,
        symbols => $symbols,
        analyzed_at => time()
    };
}

=head2 find_symbols($pattern, %options)

Find symbols matching a pattern.

=cut

sub find_symbols {
    my ($self, $pattern, %options) = @_;
    
    my $type_filter = $options{type};
    my $scope_filter = $options{scope};
    my $file_filter = $options{file};
    
    warn "[DEBUG Symbols] Finding symbols matching '$pattern'\n" if $self->{debug};
    
    my @results;
    
    # Exact match first
    if (exists $self->{symbol_index}->{$pattern}) {
        push @results, @{$self->{symbol_index}->{$pattern}};
    }
    
    # Pattern matching
    for my $symbol_name (keys %{$self->{symbol_index}}) {
        next if $symbol_name eq $pattern;  # Already added
        
        if ($symbol_name =~ /\Q$pattern\E/i) {
            push @results, @{$self->{symbol_index}->{$symbol_name}};
        }
    }
    
    # Apply filters
    if ($type_filter) {
        @results = grep { $_->{type} eq $type_filter } @results;
    }
    
    if ($scope_filter) {
        @results = grep { $_->{scope} eq $scope_filter } @results;
    }
    
    if ($file_filter) {
        my $norm_file = $self->_normalize_path($file_filter);
        @results = grep { $_->{file_key} eq $norm_file } @results;
    }
    
    warn "[DEBUG Symbols] Found ", scalar(@results), " matching symbols\n" if $self->{debug};
    
    return \@results;
}

=head2 get_file_symbols($filepath)

Get all symbols from a specific file.

=cut

sub get_file_symbols {
    my ($self, $filepath) = @_;
    
    my $file_key = $self->_normalize_path($filepath);
    
    unless (exists $self->{file_index}->{$file_key}) {
        # Try to index the file first
        $self->index_file($filepath);
    }
    
    return $self->find_symbols('', file => $filepath);
}

=head2 get_symbol_references($symbol_name)

Find all references to a symbol across indexed files.

=cut

sub get_symbol_references {
    my ($self, $symbol_name) = @_;
    
    warn "[DEBUG Symbols] Finding references to '$symbol_name'\n" if $self->{debug};
    
    my $references = [];
    
    # This is a simplified implementation
    # In a full system, this would analyze usage patterns
    for my $file_key (keys %{$self->{file_index}}) {
        my $filepath = $self->{file_index}->{$file_key}->{filepath};
        
        # Search file content for symbol usage
        if (open my $fh, '<', $filepath) {
            my $line_num = 0;
            while (my $line = <$fh>) {
                $line_num++;
                chomp $line;
                
                if ($line =~ /\Q$symbol_name\E/) {
                    push @$references, {
                        filepath => $filepath,
                        line => $line_num,
                        context => $line,
                        type => 'usage'
                    };
                }
            }
            close $fh;
        }
    }
    
    warn "[DEBUG Symbols] Found ", scalar(@$references), " references\n" if $self->{debug};
    
    return $references;
}

=head2 get_statistics()

Get symbol index statistics.

=cut

sub get_statistics {
    my ($self) = @_;
    
    my $stats = {
        indexed_files => scalar(keys %{$self->{file_index}}),
        total_symbols => 0,
        symbol_types => {}
    };
    
    for my $symbol_list (values %{$self->{symbol_index}}) {
        for my $symbol (@$symbol_list) {
            $stats->{total_symbols}++;
            $stats->{symbol_types}->{$symbol->{type}}++;
        }
    }
    
    return $stats;
}

=head2 clear_index()

Clear the symbol index.

=cut

sub clear_index {
    my ($self) = @_;
    
    warn "[DEBUG Symbols] Clearing symbol index\n" if $self->{debug};
    
    $self->{symbol_index} = {};
    $self->{file_index} = {};
    
    # Clear cache
    if (-d $self->{cache_dir}) {
        opendir my $dh, $self->{cache_dir};
        while (my $file = readdir $dh) {
            next if $file =~ /^\.\.?$/;
            unlink "$self->{cache_dir}/$file";
        }
        closedir $dh;
    }
}

=head2 _normalize_path($filepath)

Normalize file path for consistent indexing.

=cut

sub _normalize_path {
    my ($self, $filepath) = @_;
    
    # Convert to absolute path and normalize
    my $normalized = File::Spec->rel2abs($filepath);
    $normalized =~ s/\/+/\//g;  # Remove duplicate slashes
    return $normalized;
}

=head2 _cache_analysis($file_key, $analysis)

Cache analysis results.

=cut

sub _cache_analysis {
    my ($self, $file_key, $analysis) = @_;
    
    return unless -d $self->{cache_dir};
    
    my $cache_key = $file_key;
    $cache_key =~ s/[\/\\:]/_/g;  # Make filesystem safe
    
    my $cache_file = "$self->{cache_dir}/$cache_key.json";
    
    eval {
        open my $fh, '>', $cache_file;
        print $fh JSON->new->pretty->encode($analysis);
        close $fh;
    };
    
    warn "[WARN Symbols] Cache write failed for $file_key: $@\n" if $@ && $self->{debug};
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 COPYRIGHT

Copyright (c) 2025 CLIO Project. All rights reserved.

=cut

1;
