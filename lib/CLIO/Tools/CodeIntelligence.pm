package CLIO::Tools::CodeIntelligence;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use parent 'CLIO::Tools::Tool';
use File::Find;
use Cwd 'abs_path';

=head1 NAME

CLIO::Tools::CodeIntelligence - Code analysis and symbol search tool

=head1 DESCRIPTION

Provides code intelligence operations for finding symbol usages, definitions, and references.

Operations:
  list_usages - Find all usages of a symbol across the codebase

=head1 SYNOPSIS

    use CLIO::Tools::CodeIntelligence;
    
    my $tool = CLIO::Tools::CodeIntelligence->new(debug => 1);
    
    # Find symbol usages
    my $result = $tool->execute(
        { 
            operation => 'list_usages',
            symbol_name => 'MyClass',
            file_paths => ['lib/']
        },
        { session => { id => 'test' } }
    );

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = $class->SUPER::new(
        name => 'code_intelligence',
        description => q{Code analysis and symbol search operations.

Operations:
-  list_usages - Find all usages/references of a symbol
  Parameters: 
    - symbol_name (required): Symbol to search for
    - file_paths (optional): Array of paths to search in (default: current dir)
    - context_lines (optional): Number of context lines around match (default: 0)
  Returns: List of all locations where symbol appears
},
        supported_operations => [qw(
            list_usages
        )],
        %opts,
    );
    
    return $self;
}

sub route_operation {
    my ($self, $operation, $params, $context) = @_;
    
    if ($operation eq 'list_usages') {
        return $self->list_usages($params, $context);
    }
    
    return $self->error_result("Operation not implemented: $operation");
}

=head2 list_usages

Find all usages of a symbol across the codebase.

Uses git grep if available (faster), falls back to File::Find + regex search.

Parameters:
- symbol_name: Symbol to search for (required)
- file_paths: Array of paths to search (optional, default: ['.'])
- context_lines: Number of context lines (optional, default: 0)

Returns: Hash with:
- success: Boolean
- message: Summary message
- usages: Array of {file, line, line_number, context_before, context_after}
- count: Total number of usages found

=cut

sub list_usages {
    my ($self, $params, $context) = @_;
    
    my $symbol_name = $params->{symbol_name};
    my $file_paths = $params->{file_paths} || ['.'];
    my $context_lines = $params->{context_lines} || 0;
    
    return $self->error_result("Missing 'symbol_name' parameter") unless $symbol_name;
    return $self->error_result("'file_paths' must be an array") 
        unless ref($file_paths) eq 'ARRAY';
    
    print STDERR "[DEBUG][CodeIntelligence] Searching for symbol: $symbol_name\n" if should_log('DEBUG');
    print STDERR "[DEBUG][CodeIntelligence] Search paths: " . join(', ', @$file_paths) . "\n" if should_log('DEBUG');
    
    my @usages = ();
    
    # Try git grep first (much faster if in a git repo)
    if ($self->_has_git_grep()) {
        @usages = $self->_git_grep_search($symbol_name, $file_paths, $context_lines);
    } else {
        @usages = $self->_file_grep_search($symbol_name, $file_paths, $context_lines);
    }
    
    my $count = scalar(@usages);
    
    print STDERR "[DEBUG][CodeIntelligence] Found $count usages\n" if should_log('DEBUG');
    
    if ($count == 0) {
        my $action_desc = "searching for symbol '$symbol_name' (found 0 usages)";
        return $self->success_result(
            "No usages found for '$symbol_name'",
            action_description => $action_desc,
            usages => \@usages,
            count => 0,
            symbol => $symbol_name,
        );
    }
    
    # Sort by file, then line number
    @usages = sort { 
        $a->{file} cmp $b->{file} || $a->{line_number} <=> $b->{line_number}
    } @usages;
    
    my $action_desc = "searching for symbol '$symbol_name' (found $count usages)";
    
    return $self->success_result(
        "Found $count usages of '$symbol_name'",
        action_description => $action_desc,
        usages => \@usages,
        count => $count,
        symbol => $symbol_name,
    );
}

sub _has_git_grep {
    my ($self) = @_;
    
    # Check if git is available and we're in a git repo
    my $result = `git rev-parse --is-inside-work-tree 2>/dev/null`;
    return $result && $result =~ /true/;
}

sub _git_grep_search {
    my ($self, $symbol, $paths, $context) = @_;
    
    my @results = ();
    
    # Build git grep command
    my $context_flag = $context > 0 ? "-C$context" : "";
    my $paths_str = join(' ', map { quotemeta($_) } @$paths);
    
    # Use git grep with line numbers and file names
    my $cmd = "git grep -n $context_flag -F " . quotemeta($symbol) . " -- $paths_str 2>/dev/null";
    
    print STDERR "[DEBUG][CodeIntelligence] Running: $cmd\n" if should_log('DEBUG');
    
    open my $fh, '-|', $cmd or return @results;
    
    my $current_file = '';
    my @context_before = ();
    
    while (my $line = <$fh>) {
        chomp $line;
        
        # Parse git grep output: file:line:content
        if ($line =~ /^([^:]+):(\d+):(.*)$/) {
            my ($file, $line_num, $content) = ($1, $2, $3);
            
            push @results, {
                file => $file,
                line_number => int($line_num),
                line => $content,
                context_before => [@context_before],
                context_after => [],  # git grep doesn't provide easy context_after
            };
            
            @context_before = ();
        }
    }
    
    close $fh;
    
    return @results;
}

sub _file_grep_search {
    my ($self, $symbol, $paths, $context_lines) = @_;
    
    my @results = ();
    my @files_to_search = ();
    
    # Collect all files to search
    foreach my $path (@$paths) {
        if (-f $path) {
            push @files_to_search, $path;
        } elsif (-d $path) {
            find(sub {
                return unless -f $_;
                return if $_ =~ /^\./;  # Skip hidden files
                return if $_ =~ /\.(git|svn|hg)\//;  # Skip VCS dirs
                push @files_to_search, $File::Find::name;
            }, $path);
        }
    }
    
    print STDERR "[DEBUG][CodeIntelligence] Searching " . scalar(@files_to_search) . " files\n" if should_log('DEBUG');
    
    # Search each file
    foreach my $file (@files_to_search) {
        next unless -f $file && -r $file;
        
        open my $fh, '<', $file or next;
        my @lines = <$fh>;
        close $fh;
        
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ /\Q$symbol\E/) {
                my $line_num = $i + 1;
                chomp $lines[$i];
                
                # Gather context
                my @context_before = ();
                my @context_after = ();
                
                if ($context_lines > 0) {
                    my $start = ($i - $context_lines) >= 0 ? ($i - $context_lines) : 0;
                    my $end = ($i + $context_lines) <= $#lines ? ($i + $context_lines) : $#lines;
                    
                    for my $j ($start .. $i - 1) {
                        my $ctx = $lines[$j];
                        chomp $ctx;
                        push @context_before, $ctx;
                    }
                    
                    for my $j ($i + 1 .. $end) {
                        my $ctx = $lines[$j];
                        chomp $ctx;
                        push @context_after, $ctx;
                    }
                }
                
                push @results, {
                    file => $file,
                    line_number => $line_num,
                    line => $lines[$i],
                    context_before => \@context_before,
                    context_after => \@context_after,
                };
            }
        }
    }
    
    return @results;
}

1;
