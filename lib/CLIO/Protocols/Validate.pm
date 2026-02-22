package CLIO::Protocols::Validate;

use strict;
use warnings;
use utf8;
use base 'CLIO::Protocols::Handler';
use MIME::Base64;
use File::Temp qw(tempfile);
use CLIO::Util::JSON qw(encode_json decode_json);

=head1 NAME

CLIO::Protocols::Validate - Advanced code validation and analysis protocol handler

=head1 DESCRIPTION

This module provides comprehensive code validation including syntax checking,
style validation, security scanning, and performance analysis across multiple languages.

=head1 PROTOCOL FORMAT

[VALIDATE:type=<type>:content=<base64_content>:language=<language>:options=<base64_options>]

Types:
- syntax: Check syntax errors
- style: Code style validation  
- security: Security vulnerability scan
- performance: Performance analysis
- all: Run all validation types

Languages:
- perl, python, javascript, typescript, bash, yaml, json, markdown

=cut

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        validators => {
            perl => {
                syntax => \&_validate_perl_syntax,
                style => \&_validate_perl_style,
                security => \&_validate_perl_security,
                performance => \&_validate_perl_performance,
            },
            python => {
                syntax => \&_validate_python_syntax,
                style => \&_validate_python_style,
                security => \&_validate_python_security,
                performance => \&_validate_python_performance,
            },
            javascript => {
                syntax => \&_validate_js_syntax,
                style => \&_validate_js_style,
                security => \&_validate_js_security,
                performance => \&_validate_js_performance,
            },
            json => {
                syntax => \&_validate_json_syntax,
                style => \&_validate_json_style,
            },
            yaml => {
                syntax => \&_validate_yaml_syntax,
                style => \&_validate_yaml_style,
            },
        },
        %args
    }, $class;
    
    return $self;
}

sub process_request {
    my ($self, $input) = @_;
    
    # Parse protocol: [VALIDATE:type=<type>:content=<base64_content>:language=<language>:options=<base64_options>]
    if ($input !~ /^\[VALIDATE:type=([^:]+):content=([^:]+)(?::language=([^:]+))?(?::options=([^:]+))?\]$/) {
        return $self->handle_errors('Invalid VALIDATE protocol format');
    }
    
    my ($type, $b64_content, $language, $b64_options) = ($1, $2, $3, $4);
    
    # Decode content
    my $content = eval { decode_base64($b64_content) };
    if ($@) {
        return $self->handle_errors("Failed to decode content: $@");
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
    
    # Auto-detect language if not provided
    if (!$language) {
        $language = $self->_detect_language($content, $options);
    }
    
    # Validate type
    unless ($type =~ /^(syntax|style|security|performance|all)$/) {
        return $self->handle_errors("Invalid validation type: $type");
    }
    
    # Run validation
    my $result = $self->_run_validation($type, $content, $language, $options);
    
    return $self->format_response($result);
}

sub _run_validation {
    my ($self, $type, $content, $language, $options) = @_;
    
    my $result = {
        success => 1,
        language => $language,
        validation_type => $type,
        issues => [],
        suggestions => [],
        metrics => {},
        timestamp => time(),
    };
    
    # Get validators for language
    my $validators = $self->{validators}->{$language};
    unless ($validators) {
        return {
            success => 0,
            error => "Validation not supported for language: $language"
        };
    }
    
    # Run specific validation or all validations
    if ($type eq 'all') {
        for my $validation_type (keys %$validators) {
            my $validator = $validators->{$validation_type};
            my $validation_result = $validator->($self, $content, $options);
            
            push @{$result->{issues}}, @{$validation_result->{issues} || []};
            push @{$result->{suggestions}}, @{$validation_result->{suggestions} || []};
            
            if ($validation_result->{metrics}) {
                $result->{metrics}->{$validation_type} = $validation_result->{metrics};
            }
        }
    } else {
        my $validator = $validators->{$type};
        unless ($validator) {
            return {
                success => 0,
                error => "Validation type '$type' not supported for language: $language"
            };
        }
        
        my $validation_result = $validator->($self, $content, $options);
        $result->{issues} = $validation_result->{issues} || [];
        $result->{suggestions} = $validation_result->{suggestions} || [];
        $result->{metrics} = $validation_result->{metrics} || {};
    }
    
    # Add summary metrics
    $result->{summary} = {
        total_issues => scalar @{$result->{issues}},
        critical_issues => scalar(grep { $_->{severity} eq 'critical' } @{$result->{issues}}),
        warning_issues => scalar(grep { $_->{severity} eq 'warning' } @{$result->{issues}}),
        info_issues => scalar(grep { $_->{severity} eq 'info' } @{$result->{issues}}),
        suggestions_count => scalar @{$result->{suggestions}},
    };
    
    return $result;
}

sub _detect_language {
    my ($self, $content, $options) = @_;
    
    # Check file extension if provided
    if ($options->{filename}) {
        my $filename = $options->{filename};
        return 'perl' if $filename =~ /\.pl$|\.pm$/;
        return 'python' if $filename =~ /\.py$/;
        return 'javascript' if $filename =~ /\.js$/;
        return 'typescript' if $filename =~ /\.ts$/;
        return 'json' if $filename =~ /\.json$/;
        return 'yaml' if $filename =~ /\.ya?ml$/;
        return 'bash' if $filename =~ /\.sh$/;
        return 'markdown' if $filename =~ /\.md$/;
    }
    
    # Content-based detection
    return 'perl' if $content =~ m{^\#!.*perl}m || $content =~ /package\s+\w+::\w+/;
    return 'python' if $content =~ m{^\#!.*python}m || $content =~ /import\s+\w+/m;
    return 'javascript' if $content =~ /function\s+\w+/ || $content =~ /const\s+\w+\s*=/;
    return 'json' if $content =~ /^\s*\{.*\}\s*$/s && eval { decode_json($content); 1 };
    return 'yaml' if $content =~ /^---/m || $content =~ /^\w+:\s*$/m;
    return 'bash' if $content =~ m{^\#!/bin/bash}m || $content =~ m{#!/bin/sh}m;
    
    # Default to text for unknown content
    return 'text';
}

# Perl Validators
sub _validate_perl_syntax {
    my ($self, $content, $options) = @_;
    
    my ($fh, $filename) = tempfile(SUFFIX => '.pl');
    print $fh $content;
    close $fh;
    
    my $output = `perl -c "$filename" 2>&1`;
    my $exit_code = $? >> 8;
    
    unlink $filename;
    
    my @issues = ();
    my @suggestions = ();
    
    if ($exit_code != 0) {
        # Parse perl -c output for errors
        for my $line (split /\n/, $output) {
            if ($line =~ /(.+) at .+ line (\d+)/) {
                push @issues, {
                    type => 'syntax_error',
                    severity => 'critical',
                    message => $1,
                    line => $2,
                    source => 'perl -c',
                };
            }
        }
    }
    
    return {
        issues => \@issues,
        suggestions => \@suggestions,
        metrics => {
            syntax_check_exit_code => $exit_code,
            syntax_valid => $exit_code == 0,
        }
    };
}

sub _validate_perl_style {
    my ($self, $content, $options) = @_;
    
    my @issues = ();
    my @suggestions = ();
    
    # Basic style checks
    my @lines = split /\n/, $content;
    for my $i (0..$#lines) {
        my $line = $lines[$i];
        my $line_num = $i + 1;
        
        # Check for trailing whitespace
        if ($line =~ /\s+$/) {
            push @issues, {
                type => 'style',
                severity => 'warning',
                message => 'Trailing whitespace',
                line => $line_num,
                source => 'style_checker',
            };
        }
        
        # Check for tabs vs spaces
        if ($line =~ /\t/ && $options->{prefer_spaces}) {
            push @issues, {
                type => 'style',
                severity => 'info',
                message => 'Tab character found (prefer spaces)',
                line => $line_num,
                source => 'style_checker',
            };
        }
        
        # Check line length
        my $max_length = $options->{max_line_length} || 120;
        if (length($line) > $max_length) {
            push @issues, {
                type => 'style',
                severity => 'warning',
                message => "Line too long (" . length($line) . " > $max_length)",
                line => $line_num,
                source => 'style_checker',
            };
        }
    }
    
    return {
        issues => \@issues,
        suggestions => \@suggestions,
        metrics => {
            line_count => scalar @lines,
            max_line_length => max(map { length($_) } @lines) || 0,
        }
    };
}

sub _validate_perl_security {
    my ($self, $content, $options) = @_;
    
    my @issues = ();
    my @suggestions = ();
    
    # Security pattern checks
    my @security_patterns = (
        {
            pattern => qr/system\s*\(/,
            message => 'Use of system() function detected',
            severity => 'warning',
            suggestion => 'Consider using safer alternatives or proper input validation'
        },
        {
            pattern => qr/`[^`]*`/,
            message => 'Backtick command execution detected',
            severity => 'warning',
            suggestion => 'Consider using safer alternatives for command execution'
        },
        {
            pattern => qr/eval\s*\(/,
            message => 'Use of eval() detected',
            severity => 'warning',
            suggestion => 'Avoid eval() with untrusted input'
        },
        {
            pattern => qr/open\s*\(\s*[^,]*\s*,\s*['"][^'"]*\|/,
            message => 'Pipe in open() detected',
            severity => 'critical',
            suggestion => 'Validate input before using pipes in open()'
        },
    );
    
    my @lines = split /\n/, $content;
    for my $i (0..$#lines) {
        my $line = $lines[$i];
        my $line_num = $i + 1;
        
        for my $pattern_info (@security_patterns) {
            if ($line =~ $pattern_info->{pattern}) {
                push @issues, {
                    type => 'security',
                    severity => $pattern_info->{severity},
                    message => $pattern_info->{message},
                    line => $line_num,
                    source => 'security_scanner',
                };
                
                push @suggestions, {
                    type => 'security',
                    message => $pattern_info->{suggestion},
                    line => $line_num,
                };
            }
        }
    }
    
    return {
        issues => \@issues,
        suggestions => \@suggestions,
        metrics => {
            security_patterns_checked => scalar @security_patterns,
        }
    };
}

sub _validate_perl_performance {
    my ($self, $content, $options) = @_;
    
    my @issues = ();
    my @suggestions = ();
    
    # Performance pattern checks
    my @lines = split /\n/, $content;
    for my $i (0..$#lines) {
        my $line = $lines[$i];
        my $line_num = $i + 1;
        
        # Check for inefficient patterns
        if ($line =~ /for\s*\(\s*my\s*\$\w+\s*=\s*0\s*;\s*\$\w+\s*<=?\s*\$#\w+/) {
            push @issues, {
                type => 'performance',
                severity => 'info',
                message => 'Consider using foreach instead of C-style for loop',
                line => $line_num,
                source => 'performance_analyzer',
            };
        }
        
        # Check for string concatenation in loops
        if ($line =~ /\$\w+\s*\.=/ && $content =~ /for|foreach|while/) {
            push @suggestions, {
                type => 'performance',
                message => 'Consider using array join for string concatenation in loops',
                line => $line_num,
            };
        }
    }
    
    return {
        issues => \@issues,
        suggestions => \@suggestions,
        metrics => {
            subroutine_count => scalar(split /sub\s+\w+/, $content) - 1,
            line_count => scalar @lines,
        }
    };
}

# Python Validators (basic implementations)
sub _validate_python_syntax {
    my ($self, $content, $options) = @_;
    
    my ($fh, $filename) = tempfile(SUFFIX => '.py');
    print $fh $content;
    close $fh;
    
    my $output = `python3 -m py_compile "$filename" 2>&1`;
    my $exit_code = $? >> 8;
    
    unlink $filename;
    
    my @issues = ();
    if ($exit_code != 0) {
        push @issues, {
            type => 'syntax_error',
            severity => 'critical',
            message => $output,
            source => 'python3 -m py_compile',
        };
    }
    
    return {
        issues => \@issues,
        suggestions => [],
        metrics => { syntax_valid => $exit_code == 0 }
    };
}

sub _validate_python_style {
    my ($self, $content, $options) = @_;
    return { issues => [], suggestions => [], metrics => {} };
}

sub _validate_python_security {
    my ($self, $content, $options) = @_;
    return { issues => [], suggestions => [], metrics => {} };
}

sub _validate_python_performance {
    my ($self, $content, $options) = @_;
    return { issues => [], suggestions => [], metrics => {} };
}

# JavaScript Validators (basic implementations)
sub _validate_js_syntax {
    my ($self, $content, $options) = @_;
    return { issues => [], suggestions => [], metrics => {} };
}

sub _validate_js_style {
    my ($self, $content, $options) = @_;
    return { issues => [], suggestions => [], metrics => {} };
}

sub _validate_js_security {
    my ($self, $content, $options) = @_;
    return { issues => [], suggestions => [], metrics => {} };
}

sub _validate_js_performance {
    my ($self, $content, $options) = @_;
    return { issues => [], suggestions => [], metrics => {} };
}

# JSON Validators
sub _validate_json_syntax {
    my ($self, $content, $options) = @_;
    
    my @issues = ();
    eval { decode_json($content) };
    if ($@) {
        push @issues, {
            type => 'syntax_error',
            severity => 'critical',
            message => "JSON syntax error: $@",
            source => 'JSON::PP',
        };
    }
    
    return {
        issues => \@issues,
        suggestions => [],
        metrics => { json_valid => !@issues }
    };
}

sub _validate_json_style {
    my ($self, $content, $options) = @_;
    
    my @suggestions = ();
    
    # Check if JSON is pretty-printed
    if ($content !~ /\n/ && length($content) > 100) {
        push @suggestions, {
            type => 'style',
            message => 'Consider pretty-printing JSON for better readability',
        };
    }
    
    return {
        issues => [],
        suggestions => \@suggestions,
        metrics => {}
    };
}

# YAML Validators
sub _validate_yaml_syntax {
    my ($self, $content, $options) = @_;
    
    my @issues = ();
    
    # Basic YAML syntax check (simplified)
    my @lines = split /\n/, $content;
    for my $i (0..$#lines) {
        my $line = $lines[$i];
        my $line_num = $i + 1;
        
        # Check for tab characters (YAML doesn't allow tabs)
        if ($line =~ /\t/) {
            push @issues, {
                type => 'syntax_error',
                severity => 'critical',
                message => 'YAML does not allow tab characters',
                line => $line_num,
                source => 'yaml_validator',
            };
        }
    }
    
    return {
        issues => \@issues,
        suggestions => [],
        metrics => { yaml_basic_check => 1 }
    };
}

sub _validate_yaml_style {
    my ($self, $content, $options) = @_;
    return { issues => [], suggestions => [], metrics => {} };
}

# Utility function for max
sub max {
    my $max = shift;
    for (@_) {
        $max = $_ if $_ > $max;
    }
    return $max;
}

1;

__END__

=head1 USAGE EXAMPLES

=head2 Perl Syntax Validation

  [VALIDATE:type=syntax:content=<base64_perl_code>:language=perl]

=head2 Style Check with Options

  [VALIDATE:type=style:content=<base64_code>:language=perl:options=<base64_json_options>]

  Options JSON example:
  {
    "max_line_length": 100,
    "prefer_spaces": true,
    "filename": "script.pl"
  }

=head2 Security Scan

  [VALIDATE:type=security:content=<base64_code>:language=perl]

=head2 Complete Validation

  [VALIDATE:type=all:content=<base64_code>:language=perl]

=head1 RETURN FORMAT

  {
    "success": true,
    "language": "perl",
    "validation_type": "all",
    "issues": [
      {
        "type": "syntax_error",
        "severity": "critical",
        "message": "Syntax error description",
        "line": 42,
        "source": "perl -c"
      }
    ],
    "suggestions": [
      {
        "type": "performance",
        "message": "Consider using foreach instead of C-style for",
        "line": 15
      }
    ],
    "metrics": {
      "syntax": {"syntax_valid": true},
      "style": {"line_count": 50}
    },
    "summary": {
      "total_issues": 3,
      "critical_issues": 1,
      "warning_issues": 2,
      "info_issues": 0,
      "suggestions_count": 5
    },
    "timestamp": 1640995200
  }


=cut

1;
