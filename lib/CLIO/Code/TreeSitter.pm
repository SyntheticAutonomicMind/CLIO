package CLIO::Code::TreeSitter;

use strict;
use warnings;
use File::Basename;
use JSON;

=head1 NAME

CLIO::Code::TreeSitter - Tree-sitter integration for code analysis

=head1 SYNOPSIS

    use CLIO::Code::TreeSitter;
    
    my $parser = CLIO::Code::TreeSitter->new(debug => 1);
    my $ast = $parser->parse_code($code, 'perl');
    my $symbols = $parser->extract_symbols($ast);

=head1 DESCRIPTION

This module provides Tree-sitter integration for parsing and analyzing code.
Since external dependencies are not allowed, this module implements a 
simplified AST-like analysis using Perl's built-in parsing capabilities.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} || 0,
        languages => {
            perl => {
                extensions => ['.pl', '.pm', '.t'],
                keywords => [qw(use package sub my our local if elsif else unless while for foreach return die warn)]
            },
            javascript => {
                extensions => ['.js', '.jsx', '.ts', '.tsx'],
                keywords => [qw(var let const function class if else while for return import export)]
            },
            python => {
                extensions => ['.py'],
                keywords => [qw(def class if elif else while for return import from)]
            }
        }
    };
    
    return bless $self, $class;
}

=head2 parse_code($code, $language)

Parse code and return a simplified AST structure.

=cut

sub parse_code {
    my ($self, $code, $language) = @_;
    
    warn "[DEBUG TreeSitter] Parsing $language code (", length($code), " chars)\n" if $self->{debug};
    
    return undef unless $code && $language;
    
    my $lang_config = $self->{languages}->{$language};
    return undef unless $lang_config;
    
    my $ast = {
        language => $language,
        root => {
            type => 'source_file',
            children => []
        },
        metadata => {
            lines => scalar(split /\n/, $code),
            size => length($code),
            parsed_at => time()
        }
    };
    
    # Simple tokenization and structure detection
    my @lines = split /\n/, $code;
    my $line_num = 0;
    
    for my $line (@lines) {
        $line_num++;
        chomp $line;
        next if $line =~ /^\s*$/ || $line =~ /^\s*#/;  # Skip empty lines and comments
        
        my $node = $self->_parse_line($line, $line_num, $language);
        push @{$ast->{root}->{children}}, $node if $node;
    }
    
    warn "[DEBUG TreeSitter] Parsed AST with ", scalar(@{$ast->{root}->{children}}), " nodes\n" if $self->{debug};
    
    return $ast;
}

=head2 _parse_line($line, $line_num, $language)

Parse a single line and extract structural information.

=cut

sub _parse_line {
    my ($self, $line, $line_num, $language) = @_;
    
    my $trimmed = $line;
    $trimmed =~ s/^\s+|\s+$//g;
    
    my $node = {
        line => $line_num,
        text => $trimmed,
        type => 'unknown'
    };
    
    # Perl-specific parsing
    if ($language eq 'perl') {
        if ($trimmed =~ /^package\s+([A-Za-z0-9:_]+)/) {
            $node->{type} = 'package_declaration';
            $node->{name} = $1;
        } elsif ($trimmed =~ /^use\s+([A-Za-z0-9:_]+)/) {
            $node->{type} = 'use_statement';
            $node->{module} = $1;
        } elsif ($trimmed =~ /^sub\s+([A-Za-z0-9_]+)/) {
            $node->{type} = 'subroutine';  
            $node->{name} = $1;
        } elsif ($trimmed =~ /^my\s+([^=\s]+)/) {
            $node->{type} = 'variable_declaration';
            $node->{name} = $1;
        } elsif ($trimmed =~ /^our\s+([^=\s]+)/) {
            $node->{type} = 'global_variable';
            $node->{name} = $1;
        }
    }
    
    return $node;
}

=head2 extract_symbols($ast)

Extract symbols from the parsed AST.

=cut

sub extract_symbols {
    my ($self, $ast) = @_;
    
    return [] unless $ast && $ast->{root};
    
    my $symbols = [];
    
    for my $node (@{$ast->{root}->{children}}) {
        if ($node->{type} eq 'package_declaration') {
            push @$symbols, {
                type => 'package',
                name => $node->{name},
                line => $node->{line},
                scope => 'global'
            };
        } elsif ($node->{type} eq 'subroutine') {
            push @$symbols, {
                type => 'function',
                name => $node->{name},
                line => $node->{line},
                scope => 'package'
            };
        } elsif ($node->{type} eq 'variable_declaration') {
            push @$symbols, {
                type => 'variable',
                name => $node->{name},
                line => $node->{line},
                scope => 'local'
            };
        } elsif ($node->{type} eq 'global_variable') {
            push @$symbols, {
                type => 'variable',
                name => $node->{name},
                line => $node->{line},
                scope => 'global'
            };
        } elsif ($node->{type} eq 'use_statement') {
            push @$symbols, {
                type => 'import',
                name => $node->{module},
                line => $node->{line},
                scope => 'global'
            };
        }
    }
    
    warn "[DEBUG TreeSitter] Extracted ", scalar(@$symbols), " symbols\n" if $self->{debug};
    
    return $symbols;
}

=head2 analyze_file($filepath)

Analyze a file and return both AST and symbols.

=cut

sub analyze_file {
    my ($self, $filepath) = @_;
    
    return undef unless -f $filepath;
    
    warn "[DEBUG TreeSitter] Analyzing file: $filepath\n" if $self->{debug};
    
    # Determine language from extension
    my $language = $self->_detect_language($filepath);
    return undef unless $language;
    
    # Read file content
    open my $fh, '<', $filepath or do {
        warn "[ERROR TreeSitter] Cannot read file $filepath: $!\n";
        return undef;
    };
    
    my $code = do { local $/; <$fh> };
    close $fh;
    
    # Parse and analyze
    my $ast = $self->parse_code($code, $language);
    return undef unless $ast;
    
    my $symbols = $self->extract_symbols($ast);
    
    return {
        filepath => $filepath,
        language => $language,
        ast => $ast,
        symbols => $symbols,
        analyzed_at => time()
    };
}

=head2 _detect_language($filepath)

Detect programming language from file extension.

=cut

sub _detect_language {
    my ($self, $filepath) = @_;
    
    my $ext = '.' . (split /\./, basename($filepath))[-1];
    
    for my $lang (keys %{$self->{languages}}) {
        my $extensions = $self->{languages}->{$lang}->{extensions};
        return $lang if grep { $_ eq $ext } @$extensions;
    }
    
    return undef;
}

=head2 get_supported_languages()

Return list of supported languages.

=cut

sub get_supported_languages {
    my ($self) = @_;
    return keys %{$self->{languages}};
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 COPYRIGHT

Copyright (c) 2025 CLIO Project. All rights reserved.

=cut

1;
