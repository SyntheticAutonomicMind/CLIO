package CLIO::Code::Chunker;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use File::Basename;
use CLIO::Core::Logger qw(should_log);
use Exporter 'import';

our @EXPORT_OK = qw(chunk_file chunk_text get_chunker);

=head1 NAME

CLIO::Code::Chunker - Split code into embeddable chunks

=head1 DESCRIPTION

Splits source code files into logical chunks for embedding.
Language-aware chunking for Perl, Python, JavaScript, Go, etc.
Falls back to sliding window for unknown file types.

Each chunk is sized for optimal embedding (~50-150 lines).

=head1 SYNOPSIS

    use CLIO::Code::Chunker qw(chunk_file);
    
    my $chunks = chunk_file('lib/Module.pm');
    # Returns: [{content => '...', start_line => 1, end_line => 50}, ...]

=cut

# Language detection by extension
my %LANG_MAP = (
    '.pm'   => 'perl',
    '.pl'   => 'perl',
    '.t'    => 'perl',
    '.py'   => 'python',
    '.pyw'  => 'python',
    '.js'   => 'javascript',
    '.jsx'  => 'javascript',
    '.ts'   => 'typescript',
    '.tsx'  => 'typescript',
    '.go'   => 'go',
    '.rs'   => 'rust',
    '.rb'   => 'ruby',
    '.java' => 'java',
    '.c'    => 'c',
    '.cpp'  => 'cpp',
    '.h'    => 'c',
    '.hpp'  => 'cpp',
    '.cs'   => 'csharp',
    '.php'  => 'php',
    '.sh'   => 'shell',
    '.bash' => 'shell',
    '.zsh'  => 'shell',
    '.md'   => 'markdown',
    '.txt'  => 'text',
    '.json' => 'json',
    '.yaml' => 'yaml',
    '.yml'  => 'yaml',
);

# Singleton
my $_instance;

=head2 new

Create a new Chunker instance.

    my $chunker = CLIO::Code::Chunker->new(
        chunk_size => 100,   # Target lines per chunk
        overlap    => 10,    # Lines of overlap between chunks
        debug      => 1,
    );

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chunk_size => $args{chunk_size} // 80,   # Target ~80 lines
        overlap    => $args{overlap} // 10,      # 10 lines overlap
        debug      => $args{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

=head2 get_chunker

Get singleton chunker instance.

=cut

sub get_chunker {
    my (%args) = @_;
    $_instance ||= __PACKAGE__->new(%args);
    return $_instance;
}

=head2 chunk_file

Chunk a file into embeddable segments.

    my $chunks = $chunker->chunk_file('/path/to/file.pm');
    
Returns arrayref of chunks:
    [
        {
            content    => 'sub foo { ... }',
            start_line => 10,
            end_line   => 45,
            type       => 'function',  # or 'class', 'section', etc.
        },
        ...
    ]

=cut

sub chunk_file {
    my ($self, $path, %opts) = @_;
    
    # Allow function call style
    unless (ref $self) {
        my $chunker = get_chunker();
        return $chunker->chunk_file($path, %opts);
    }
    
    unless (-f $path && -r $path) {
        print STDERR "[WARN][Chunker] Cannot read file: $path\n"
            if should_log('WARNING');
        return [];
    }
    
    # Skip binary files
    unless (-T $path) {
        print STDERR "[DEBUG][Chunker] Skipping binary file: $path\n"
            if $self->{debug};
        return [];
    }
    
    # Read file content
    my $content;
    {
        open my $fh, '<:encoding(UTF-8)', $path or return [];
        local $/;
        $content = <$fh>;
        close $fh;
    }
    
    return $self->chunk_text($content, path => $path, %opts);
}

=head2 chunk_text

Chunk text content directly.

    my $chunks = $chunker->chunk_text($content, path => 'file.pm');

=cut

sub chunk_text {
    my ($self, $content, %opts) = @_;
    
    return [] unless defined $content && length($content);
    
    my $path = $opts{path} || 'unknown';
    my $lang = $self->_detect_language($path);
    
    print STDERR "[DEBUG][Chunker] Chunking $path (lang=$lang)\n"
        if $self->{debug};
    
    # Language-specific chunking
    my $chunks;
    if ($lang eq 'perl') {
        $chunks = $self->_chunk_perl($content, $path);
    }
    elsif ($lang eq 'python') {
        $chunks = $self->_chunk_python($content, $path);
    }
    elsif ($lang =~ /^(javascript|typescript)$/) {
        $chunks = $self->_chunk_js($content, $path);
    }
    elsif ($lang eq 'go') {
        $chunks = $self->_chunk_go($content, $path);
    }
    else {
        # Fallback to sliding window
        $chunks = $self->_chunk_sliding_window($content, $path);
    }
    
    # If language-specific chunking produced nothing, use sliding window
    if (!$chunks || !@$chunks) {
        $chunks = $self->_chunk_sliding_window($content, $path);
    }
    
    print STDERR "[DEBUG][Chunker] Produced " . scalar(@$chunks) . " chunks\n"
        if $self->{debug};
    
    return $chunks;
}

# Detect language from file path
sub _detect_language {
    my ($self, $path) = @_;
    
    my (undef, undef, $ext) = fileparse($path, qr/\.[^.]*/);
    return $LANG_MAP{lc($ext)} || 'unknown';
}

# Perl-specific chunking (subs, packages)
sub _chunk_perl {
    my ($self, $content, $path) = @_;
    
    my @lines = split /\n/, $content;
    my @chunks;
    my $current_start = 0;
    my $current_type = 'header';
    my $brace_depth = 0;
    my $in_pod = 0;
    
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        
        # POD handling
        if ($line =~ /^=(?:head|cut|pod|over|item|back|begin|end|for|encoding)/) {
            $in_pod = ($line =~ /^=cut/) ? 0 : 1;
            next;
        }
        next if $in_pod;
        
        # Package declaration - start new chunk
        if ($line =~ /^package\s+[\w:]+\s*;/) {
            if ($current_start < $i) {
                push @chunks, $self->_make_chunk(\@lines, $current_start, $i - 1, $current_type, $path);
            }
            $current_start = $i;
            $current_type = 'package';
            next;
        }
        
        # Sub declaration - start new chunk
        if ($line =~ /^sub\s+\w+/) {
            if ($current_start < $i && $current_type ne 'header') {
                push @chunks, $self->_make_chunk(\@lines, $current_start, $i - 1, $current_type, $path);
            }
            $current_start = $i;
            $current_type = 'function';
            next;
        }
        
        # Force split on very long chunks
        if ($i - $current_start >= $self->{chunk_size} * 2) {
            push @chunks, $self->_make_chunk(\@lines, $current_start, $i, $current_type, $path);
            $current_start = $i + 1;
        }
    }
    
    # Final chunk
    if ($current_start <= $#lines) {
        push @chunks, $self->_make_chunk(\@lines, $current_start, $#lines, $current_type, $path);
    }
    
    return \@chunks;
}

# Python-specific chunking (defs, classes)
sub _chunk_python {
    my ($self, $content, $path) = @_;
    
    my @lines = split /\n/, $content;
    my @chunks;
    my $current_start = 0;
    my $current_type = 'header';
    
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        
        # Class or function at column 0 (top-level)
        if ($line =~ /^(class|def|async\s+def)\s+\w+/) {
            if ($current_start < $i) {
                push @chunks, $self->_make_chunk(\@lines, $current_start, $i - 1, $current_type, $path);
            }
            $current_start = $i;
            $current_type = ($1 eq 'class') ? 'class' : 'function';
            next;
        }
        
        # Force split on very long chunks
        if ($i - $current_start >= $self->{chunk_size} * 2) {
            push @chunks, $self->_make_chunk(\@lines, $current_start, $i, $current_type, $path);
            $current_start = $i + 1;
        }
    }
    
    # Final chunk
    if ($current_start <= $#lines) {
        push @chunks, $self->_make_chunk(\@lines, $current_start, $#lines, $current_type, $path);
    }
    
    return \@chunks;
}

# JavaScript/TypeScript chunking
sub _chunk_js {
    my ($self, $content, $path) = @_;
    
    my @lines = split /\n/, $content;
    my @chunks;
    my $current_start = 0;
    my $current_type = 'header';
    
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        
        # Class, function, export at column 0
        if ($line =~ /^(?:export\s+)?(?:default\s+)?(?:class|function|const|let|var|async\s+function)\s+\w+/) {
            if ($current_start < $i) {
                push @chunks, $self->_make_chunk(\@lines, $current_start, $i - 1, $current_type, $path);
            }
            $current_start = $i;
            $current_type = ($line =~ /class/) ? 'class' : 'function';
            next;
        }
        
        # Force split
        if ($i - $current_start >= $self->{chunk_size} * 2) {
            push @chunks, $self->_make_chunk(\@lines, $current_start, $i, $current_type, $path);
            $current_start = $i + 1;
        }
    }
    
    # Final chunk
    if ($current_start <= $#lines) {
        push @chunks, $self->_make_chunk(\@lines, $current_start, $#lines, $current_type, $path);
    }
    
    return \@chunks;
}

# Go-specific chunking (func, type)
sub _chunk_go {
    my ($self, $content, $path) = @_;
    
    my @lines = split /\n/, $content;
    my @chunks;
    my $current_start = 0;
    my $current_type = 'header';
    
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        
        # func or type at column 0
        if ($line =~ /^(func|type)\s+/) {
            if ($current_start < $i) {
                push @chunks, $self->_make_chunk(\@lines, $current_start, $i - 1, $current_type, $path);
            }
            $current_start = $i;
            $current_type = ($1 eq 'func') ? 'function' : 'type';
            next;
        }
        
        # Force split
        if ($i - $current_start >= $self->{chunk_size} * 2) {
            push @chunks, $self->_make_chunk(\@lines, $current_start, $i, $current_type, $path);
            $current_start = $i + 1;
        }
    }
    
    # Final chunk
    if ($current_start <= $#lines) {
        push @chunks, $self->_make_chunk(\@lines, $current_start, $#lines, $current_type, $path);
    }
    
    return \@chunks;
}

# Sliding window fallback for unknown languages
sub _chunk_sliding_window {
    my ($self, $content, $path) = @_;
    
    my @lines = split /\n/, $content;
    my @chunks;
    my $chunk_size = $self->{chunk_size};
    my $overlap = $self->{overlap};
    my $step = $chunk_size - $overlap;
    
    for (my $start = 0; $start < @lines; $start += $step) {
        my $end = $start + $chunk_size - 1;
        $end = $#lines if $end > $#lines;
        
        push @chunks, $self->_make_chunk(\@lines, $start, $end, 'section', $path);
        
        last if $end >= $#lines;
    }
    
    return \@chunks;
}

# Create a chunk hash
sub _make_chunk {
    my ($self, $lines, $start, $end, $type, $path) = @_;
    
    my $content = join("\n", @$lines[$start .. $end]);
    
    # Skip empty chunks
    return () unless $content =~ /\S/;
    
    return {
        content    => $content,
        start_line => $start + 1,  # 1-indexed
        end_line   => $end + 1,
        type       => $type,
        path       => $path,
    };
}

=head2 should_index

Check if a file should be indexed.

    if ($chunker->should_index($path)) { ... }

Uses git ls-files to determine if file is tracked. Falls back to heuristics
if not in a git repository.

=cut

sub should_index {
    my ($self, $path) = @_;
    
    # Check if file is tracked by git (preferred method)
    if ($self->_is_git_tracked($path)) {
        # Still skip binary files
        return 0 unless -f $path && -r $path && -T $path;
        return 1;
    }
    
    # Fallback: if not in git repo, use heuristics
    return $self->_should_index_heuristic($path);
}

# Check if file is tracked by git
sub _is_git_tracked {
    my ($self, $path) = @_;
    
    # Cache git-tracked files on first call
    unless (defined $self->{_git_files}) {
        $self->{_git_files} = {};
        
        # Try to get list of tracked files
        my $output = `git ls-files 2>/dev/null`;
        if ($? == 0 && $output) {
            for my $file (split /\n/, $output) {
                $self->{_git_files}{$file} = 1;
            }
            $self->{_in_git_repo} = 1;
        } else {
            $self->{_in_git_repo} = 0;
        }
    }
    
    # If not in a git repo, return false to trigger heuristic fallback
    return 0 unless $self->{_in_git_repo};
    
    # Normalize path
    my $normalized = $path;
    $normalized =~ s{^\./}{};  # Remove leading ./
    
    return exists $self->{_git_files}{$normalized};
}

# Heuristic fallback for non-git directories
sub _should_index_heuristic {
    my ($self, $path) = @_;
    
    # Skip hidden files/directories
    return 0 if $path =~ m{(^|/)\.[^/]+};
    
    # Skip common non-code directories
    return 0 if $path =~ m{(^|/)(node_modules|vendor|target|build|dist|__pycache__|\.cache)/};
    
    # Skip common binary extensions
    return 0 if $path =~ /\.(png|jpg|jpeg|gif|ico|svg|woff|ttf|eot|pyc|o|a|so|dll|exe|class|jar)$/i;
    
    # Check file is text and readable
    return 0 unless -f $path && -r $path && -T $path;
    
    return 1;
}

1;

=head1 CHUNK TYPES

- package: Package/module declaration
- class: Class definition
- function: Function/method definition
- type: Type/struct declaration (Go, Rust)
- header: File header/imports
- section: Generic section (sliding window)

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0-only

=cut
