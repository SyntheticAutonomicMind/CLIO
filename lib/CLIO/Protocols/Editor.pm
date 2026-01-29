package CLIO::Protocols::Editor;

use strict;
use warnings;
use base 'CLIO::Protocols::Handler';
use MIME::Base64;
use JSON::PP;
use File::Temp qw(tempfile);

=head1 NAME

CLIO::Protocols::Editor - Code modification and editing protocol handler

=head1 DESCRIPTION

This module provides precise code editing capabilities including file modifications,
refactoring operations, code generation, and formatting. It focuses on the actual
implementation of changes designed by the Architect component.

=head1 PROTOCOL FORMAT

[EDITOR:action=<action>:target=<base64_target>:content=<base64_content>:options=<base64_options>]

Actions:
- edit: Modify existing code
- create: Create new code/file
- refactor: Refactor existing code
- format: Format/style code
- generate: Generate code from template
- patch: Apply code patch
- merge: Merge code changes

Target:
- file_path: Path to target file
- function_name: Specific function to edit
- class_name: Specific class to modify
- line_range: Specific line range

Content:
- new_code: New code content
- modifications: List of modifications
- template: Code generation template
- patch_data: Patch information

=cut

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        formatters => {
            perl => \&_format_perl_code,
            python => \&_format_python_code,
            javascript => \&_format_javascript_code,
            json => \&_format_json_code,
        },
        templates => {},  # Initialize empty, populate below
        edit_strategies => {
            line_replacement => \&_edit_by_line_replacement,
            function_replacement => \&_edit_by_function_replacement,
            block_insertion => \&_edit_by_block_insertion,
            pattern_replacement => \&_edit_by_pattern_replacement,
        },
        %args
    }, $class;
    
    # Populate templates after $self is blessed
    $self->{templates} = {
        perl => {
            module => $self->_get_perl_module_template(),
            function => $self->_get_perl_function_template(),
            test => $self->_get_perl_test_template(),
        },
        python => {
            module => $self->_get_python_module_template(),
            function => $self->_get_python_function_template(),
            class => $self->_get_python_class_template(),
        },
    };
    
    return $self;
}

sub process_request {
    my ($self, $input) = @_;
    
    # Parse protocol: [EDITOR:action=<action>:target=<base64_target>:content=<base64_content>:options=<base64_options>]
    if ($input !~ /^\[EDITOR:action=([^:]+):target=([^:]+):content=([^:]+)(?::options=([^:]+))?\]$/) {
        return $self->handle_errors('Invalid EDITOR protocol format');
    }
    
    my ($action, $b64_target, $b64_content, $b64_options) = ($1, $2, $3, $4);
    
    # Decode target specification
    my $target = eval { decode_base64($b64_target) };
    if ($@) {
        return $self->handle_errors("Failed to decode target: $@");
    }
    
    # Parse target if it's JSON
    my $target_spec = {};
    if ($target =~ /^\s*\{/) {
        $target_spec = eval { decode_json($target) };
        if ($@) {
            $target_spec = { file_path => $target };
        }
    } else {
        $target_spec = { file_path => $target };
    }
    
    # Decode content
    my $content = eval { decode_base64($b64_content) };
    if ($@) {
        return $self->handle_errors("Failed to decode content: $@");
    }
    
    # Parse content if it's JSON
    my $content_spec = {};
    if ($content =~ /^\s*\{/) {
        $content_spec = eval { decode_json($content) };
        if ($@) {
            $content_spec = { new_code => $content };
        }
    } else {
        $content_spec = { new_code => $content };
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
    my $method = "_handle_$action";
    if ($self->can($method)) {
        return $self->$method($target_spec, $content_spec, $options);
    } else {
        return $self->handle_errors("Unknown action: $action");
    }
}

sub _handle_edit {
    my ($self, $target_spec, $content_spec, $options) = @_;
    
    my $file_path = $target_spec->{file_path};
    unless ($file_path) {
        return $self->handle_errors("file_path required for edit action");
    }
    
    # Read existing file content
    my $original_content = '';
    if (-f $file_path) {
        local $/;
        open my $fh, '<', $file_path or return $self->handle_errors("Cannot read $file_path: $!");
        $original_content = <$fh>;
        close $fh;
    }
    
    # Determine edit strategy
    my $strategy = $options->{edit_strategy} || 'smart_replacement';
    my $modified_content = $self->_apply_edit_strategy($original_content, $target_spec, $content_spec, $strategy, $options);
    
    # Create backup if requested
    if ($options->{create_backup}) {
        my $backup_path = "$file_path.backup." . time();
        open my $backup_fh, '>', $backup_path or return $self->handle_errors("Cannot create backup: $!");
        print $backup_fh $original_content;
        close $backup_fh;
    }
    
    # Write modified content
    open my $fh, '>', $file_path or return $self->handle_errors("Cannot write $file_path: $!");
    print $fh $modified_content;
    close $fh;
    
    # Generate diff for review
    my $diff = $self->_generate_diff($original_content, $modified_content, $file_path);
    
    my $result = {
        success => 1,
        action => 'edit',
        file_path => $file_path,
        changes_applied => 1,
        diff => $diff,
        original_size => length($original_content),
        modified_size => length($modified_content),
        edit_strategy => $strategy,
        backup_created => $options->{create_backup} ? 1 : 0,
    };
    
    return $self->format_response($result);
}

sub _handle_create {
    my ($self, $target_spec, $content_spec, $options) = @_;
    
    my $file_path = $target_spec->{file_path};
    unless ($file_path) {
        return $self->handle_errors("file_path required for create action");
    }
    
    # Check if file already exists
    if (-f $file_path && !$options->{overwrite}) {
        return $self->handle_errors("File $file_path already exists (use overwrite option to replace)");
    }
    
    # Get content to create
    my $new_content = $content_spec->{new_code} || '';
    
    # Apply template if specified
    if ($content_spec->{template}) {
        $new_content = $self->_apply_template($content_spec->{template}, $content_spec->{template_data} || {}, $options);
    }
    
    # Format code if requested
    if ($options->{auto_format}) {
        my $language = $self->_detect_language($file_path, $new_content);
        if ($self->{formatters}->{$language}) {
            $new_content = $self->{formatters}->{$language}->($self, $new_content, $options);
        }
    }
    
    # Create directory if it doesn't exist
    if ($file_path =~ m{^(.+)/[^/]+$}) {
        my $dir = $1;
        unless (-d $dir) {
            require File::Path;
            File::Path::make_path($dir) or return $self->handle_errors("Cannot create directory $dir: $!");
        }
    }
    
    # Write file
    open my $fh, '>', $file_path or return $self->handle_errors("Cannot create $file_path: $!");
    print $fh $new_content;
    close $fh;
    
    my $result = {
        success => 1,
        action => 'create',
        file_path => $file_path,
        file_created => 1,
        content_size => length($new_content),
        template_used => $content_spec->{template} ? 1 : 0,
        formatted => $options->{auto_format} ? 1 : 0,
    };
    
    return $self->format_response($result);
}

sub _handle_refactor {
    my ($self, $target_spec, $content_spec, $options) = @_;
    
    my $file_path = $target_spec->{file_path};
    unless ($file_path) {
        return $self->handle_errors("file_path required for refactor action");
    }
    
    # Read existing content
    local $/;
    open my $fh, '<', $file_path or return $self->handle_errors("Cannot read $file_path: $!");
    my $original_content = <$fh>;
    close $fh;
    
    # Apply refactoring operations
    my $refactored_content = $original_content;
    my @operations_applied = ();
    
    if ($content_spec->{refactoring_operations}) {
        for my $operation (@{$content_spec->{refactoring_operations}}) {
            my $operation_result = $self->_apply_refactoring_operation($refactored_content, $operation, $options);
            if ($operation_result->{success}) {
                $refactored_content = $operation_result->{content};
                push @operations_applied, $operation->{type};
            }
        }
    }
    
    # Write refactored content
    open my $out_fh, '>', $file_path or return $self->handle_errors("Cannot write $file_path: $!");
    print $out_fh $refactored_content;
    close $out_fh;
    
    my $diff = $self->_generate_diff($original_content, $refactored_content, $file_path);
    
    my $result = {
        success => 1,
        action => 'refactor',
        file_path => $file_path,
        operations_applied => \@operations_applied,
        diff => $diff,
        original_size => length($original_content),
        refactored_size => length($refactored_content),
    };
    
    return $self->format_response($result);
}

sub _handle_format {
    my ($self, $target_spec, $content_spec, $options) = @_;
    
    my $file_path = $target_spec->{file_path};
    my $content_to_format = $content_spec->{new_code};
    
    # If no content provided, read from file
    if (!$content_to_format && $file_path) {
        local $/;
        open my $fh, '<', $file_path or return $self->handle_errors("Cannot read $file_path: $!");
        $content_to_format = <$fh>;
        close $fh;
    }
    
    unless ($content_to_format) {
        return $self->handle_errors("No content provided to format");
    }
    
    # Detect language
    my $language = $options->{language} || $self->_detect_language($file_path || '', $content_to_format);
    
    # Apply formatter
    my $formatted_content = $content_to_format;
    if ($self->{formatters}->{$language}) {
        $formatted_content = $self->{formatters}->{$language}->($self, $content_to_format, $options);
    }
    
    # Write back if file path provided
    if ($file_path && $options->{write_file}) {
        open my $fh, '>', $file_path or return $self->handle_errors("Cannot write $file_path: $!");
        print $fh $formatted_content;
        close $fh;
    }
    
    my $result = {
        success => 1,
        action => 'format',
        language => $language,
        formatted_content => $formatted_content,
        original_size => length($content_to_format),
        formatted_size => length($formatted_content),
        file_updated => ($file_path && $options->{write_file}) ? 1 : 0,
    };
    
    return $self->format_response($result);
}

sub _handle_generate {
    my ($self, $target_spec, $content_spec, $options) = @_;
    
    my $template_name = $content_spec->{template};
    unless ($template_name) {
        return $self->handle_errors("template required for generate action");
    }
    
    my $language = $options->{language} || 'perl';
    my $template_data = $content_spec->{template_data} || {};
    
    # Apply template
    my $generated_content = $self->_apply_template($template_name, $template_data, $options, $language);
    
    # Write to file if path provided
    my $file_path = $target_spec->{file_path};
    if ($file_path) {
        open my $fh, '>', $file_path or return $self->handle_errors("Cannot write $file_path: $!");
        print $fh $generated_content;
        close $fh;
    }
    
    my $result = {
        success => 1,
        action => 'generate',
        template => $template_name,
        language => $language,
        generated_content => $generated_content,
        content_size => length($generated_content),
        file_created => $file_path ? 1 : 0,
    };
    
    return $self->format_response($result);
}

sub _handle_patch {
    my ($self, $target_spec, $content_spec, $options) = @_;
    
    my $file_path = $target_spec->{file_path};
    unless ($file_path) {
        return $self->handle_errors("file_path required for patch action");
    }
    
    # Read original content
    local $/;
    open my $fh, '<', $file_path or return $self->handle_errors("Cannot read $file_path: $!");
    my $original_content = <$fh>;
    close $fh;
    
    # Apply patch
    my $patch_data = $content_spec->{patch_data};
    my $patched_content = $self->_apply_patch($original_content, $patch_data, $options);
    
    # Write patched content
    open my $out_fh, '>', $file_path or return $self->handle_errors("Cannot write $file_path: $!");
    print $out_fh $patched_content;
    close $out_fh;
    
    my $result = {
        success => 1,
        action => 'patch',
        file_path => $file_path,
        patch_applied => 1,
        original_size => length($original_content),
        patched_size => length($patched_content),
    };
    
    return $self->format_response($result);
}

sub _handle_merge {
    my ($self, $target_spec, $content_spec, $options) = @_;
    
    my $base_content = $content_spec->{base_content} || '';
    my $changes = $content_spec->{changes} || [];
    
    my $merged_content = $base_content;
    my @merge_conflicts = ();
    
    # Apply changes sequentially
    for my $change (@$changes) {
        my $merge_result = $self->_apply_merge_change($merged_content, $change, $options);
        if ($merge_result->{conflicts}) {
            push @merge_conflicts, @{$merge_result->{conflicts}};
        }
        $merged_content = $merge_result->{content};
    }
    
    # Write merged content if file path provided
    my $file_path = $target_spec->{file_path};
    if ($file_path) {
        open my $fh, '>', $file_path or return $self->handle_errors("Cannot write $file_path: $!");
        print $fh $merged_content;
        close $fh;
    }
    
    my $result = {
        success => 1,
        action => 'merge',
        merged_content => $merged_content,
        changes_applied => scalar @$changes,
        conflicts => \@merge_conflicts,
        conflict_count => scalar @merge_conflicts,
        file_updated => $file_path ? 1 : 0,
    };
    
    return $self->format_response($result);
}

# Edit Strategy Methods
sub _apply_edit_strategy {
    my ($self, $original_content, $target_spec, $content_spec, $strategy, $options) = @_;
    
    if ($strategy eq 'smart_replacement') {
        return $self->_smart_replacement($original_content, $target_spec, $content_spec, $options);
    } elsif ($strategy eq 'line_replacement') {
        return $self->_line_replacement($original_content, $target_spec, $content_spec, $options);
    } elsif ($strategy eq 'function_replacement') {
        return $self->_function_replacement($original_content, $target_spec, $content_spec, $options);
    } elsif ($strategy eq 'block_insertion') {
        return $self->_block_insertion($original_content, $target_spec, $content_spec, $options);
    } else {
        # Default to full replacement
        return $content_spec->{new_code} || $original_content;
    }
}

sub _smart_replacement {
    my ($self, $original_content, $target_spec, $content_spec, $options) = @_;
    
    # Implement smart replacement logic based on target specification
    if ($target_spec->{function_name}) {
        return $self->_function_replacement($original_content, $target_spec, $content_spec, $options);
    } elsif ($target_spec->{line_range}) {
        return $self->_line_replacement($original_content, $target_spec, $content_spec, $options);
    } elsif ($target_spec->{pattern}) {
        return $self->_pattern_replacement($original_content, $target_spec, $content_spec, $options);
    } else {
        # Full file replacement
        return $content_spec->{new_code} || $original_content;
    }
}

sub _line_replacement {
    my ($self, $original_content, $target_spec, $content_spec, $options) = @_;
    
    my @lines = split /\n/, $original_content;
    my $line_range = $target_spec->{line_range};
    my $new_code = $content_spec->{new_code} || '';
    
    if ($line_range =~ /^(\d+)-(\d+)$/) {
        my ($start, $end) = ($1 - 1, $2 - 1);  # Convert to 0-based indexing
        
        # Replace lines in range
        splice @lines, $start, $end - $start + 1, split(/\n/, $new_code);
    } elsif ($line_range =~ /^(\d+)$/) {
        my $line_num = $1 - 1;  # Convert to 0-based indexing
        $lines[$line_num] = $new_code;
    }
    
    return join("\n", @lines);
}

sub _function_replacement {
    my ($self, $original_content, $target_spec, $content_spec, $options) = @_;
    
    my $function_name = $target_spec->{function_name};
    my $new_function = $content_spec->{new_code} || '';
    
    # Simple Perl function replacement (this could be made more sophisticated)
    my $function_pattern = qr/^sub\s+\Q$function_name\E\s*\{.*?^}/sm;
    
    if ($original_content =~ $function_pattern) {
        $original_content =~ s/$function_pattern/$new_function/;
    } else {
        # Function not found, append at end
        $original_content .= "\n\n$new_function\n";
    }
    
    return $original_content;
}

sub _pattern_replacement {
    my ($self, $original_content, $target_spec, $content_spec, $options) = @_;
    
    my $pattern = $target_spec->{pattern};
    my $replacement = $content_spec->{new_code} || '';
    
    # Apply pattern replacement
    if ($options->{global_replace}) {
        $original_content =~ s/$pattern/$replacement/g;
    } else {
        $original_content =~ s/$pattern/$replacement/;
    }
    
    return $original_content;
}

sub _block_insertion {
    my ($self, $original_content, $target_spec, $content_spec, $options) = @_;
    
    my $insertion_point = $target_spec->{insertion_point} || 'end';
    my $new_block = $content_spec->{new_code} || '';
    
    if ($insertion_point eq 'beginning') {
        return "$new_block\n$original_content";
    } elsif ($insertion_point eq 'end') {
        return "$original_content\n$new_block";
    } elsif ($insertion_point =~ /^line:(\d+)$/) {
        my $line_num = $1;
        my @lines = split /\n/, $original_content;
        splice @lines, $line_num - 1, 0, split(/\n/, $new_block);
        return join("\n", @lines);
    }
    
    return $original_content;
}

# Utility Methods
sub _generate_diff {
    my ($self, $original, $modified, $filename) = @_;
    
    eval { require Text::Diff };
    if ($@) {
        return "Diff generation not available (Text::Diff not installed)";
    }
    
    return Text::Diff::diff(\$original, \$modified, {
        FILENAME_A => "$filename (original)",
        FILENAME_B => "$filename (modified)",
        STYLE => "Unified",
    });
}

sub _detect_language {
    my ($self, $file_path, $content) = @_;
    
    # Detect by file extension
    if ($file_path =~ /\.pl$|\.pm$/) { return 'perl' }
    if ($file_path =~ /\.py$/) { return 'python' }
    if ($file_path =~ /\.js$/) { return 'javascript' }
    if ($file_path =~ /\.json$/) { return 'json' }
    
    # Detect by content
    if ($content =~ m{^\#!.*perl}m) { return 'perl' }
    if ($content =~ m{^\#!.*python}m) { return 'python' }
    if ($content =~ /package\s+\w+::\w+/) { return 'perl' }
    
    return 'text';
}

# Code Formatters
sub _format_perl_code {
    my ($self, $content, $options) = @_;
    
    # Basic Perl formatting (could be enhanced with Perl::Tidy)
    my @lines = split /\n/, $content;
    my @formatted_lines = ();
    my $indent_level = 0;
    
    for my $line (@lines) {
        # Remove trailing whitespace
        $line =~ s/\s+$//;
        
        # Adjust indentation
        if ($line =~ /^\s*\}/) {
            $indent_level-- if $indent_level > 0;
        }
        
        my $indent = '    ' x $indent_level;
        $line =~ s/^\s*/$indent/;
        
        push @formatted_lines, $line;
        
        if ($line =~ /\{\s*$/) {
            $indent_level++;
        }
    }
    
    return join("\n", @formatted_lines);
}

sub _format_python_code {
    my ($self, $content, $options) = @_;
    # Basic Python formatting (could be enhanced with autopep8 or black)
    return $content;  # Placeholder
}

sub _format_javascript_code {
    my ($self, $content, $options) = @_;
    # Basic JavaScript formatting (could be enhanced with prettier)
    return $content;  # Placeholder
}

sub _format_json_code {
    my ($self, $content, $options) = @_;
    
    eval {
        my $json = decode_json($content);
        my $json_obj = JSON::PP->new->pretty->canonical;
        return $json_obj->encode($json);
    };
    
    return $content;  # Return original if parsing fails
}

# Template Methods
sub _apply_template {
    my ($self, $template_name, $template_data, $options, $language) = @_;
    
    $language ||= 'perl';
    my $templates = $self->{templates}->{$language} || {};
    my $template = $templates->{$template_name};
    
    unless ($template) {
        return "# Template '$template_name' not found for language '$language'";
    }
    
    # Simple template variable substitution
    my $result = $template;
    for my $key (keys %$template_data) {
        my $value = $template_data->{$key};
        $result =~ s/\{\{\s*\Q$key\E\s*\}\}/$value/g;
    }
    
    return $result;
}

# Template Definitions
sub _get_perl_module_template {
    return <<'EOF';
package {{module_name}};

use strict;
use warnings;

=head1 NAME

{{module_name}} - {{description}}

=head1 SYNOPSIS

  use {{module_name}};
  
  # Usage example

=head1 DESCRIPTION

{{description}}

=cut

1;

__END__

=head1 AUTHOR

{{author}}

=head1 COPYRIGHT AND LICENSE

{{license}}
EOF
}

sub _get_perl_function_template {
    return <<'EOF';
sub {{function_name}} {
    my ({{parameters}}) = @_;
    
    # {{description}}
    
    {{function_body}}
}
EOF
}

sub _get_perl_test_template {
    return <<'EOF';
#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use_ok('{{module_name}}');

# Test cases
{{test_cases}}

done_testing();
EOF
}

sub _get_python_module_template {
    return <<'EOF';
"""
{{module_name}} - {{description}}

{{detailed_description}}
"""

class {{class_name}}:
    """{{class_description}}"""
    
    def __init__(self{{init_parameters}}):
        """Initialize {{class_name}}"""
        {{init_body}}
    
    {{methods}}

if __name__ == "__main__":
    # Test/example code
    pass
EOF
}

sub _get_python_function_template {
    return <<'EOF';
def {{function_name}}({{parameters}}):
    """{{description}}
    
    Args:
        {{args_description}}
    
    Returns:
        {{return_description}}
    """
    {{function_body}}
EOF
}

sub _get_python_class_template {
    return <<'EOF';
class {{class_name}}:
    """{{description}}"""
    
    def __init__(self{{init_parameters}}):
        """Initialize {{class_name}}"""
        {{init_body}}
EOF
}

# Stub methods for advanced functionality
sub _apply_refactoring_operation { return { success => 1, content => $_[1] } }
sub _apply_patch { return $_[1] }
sub _apply_merge_change { return { content => $_[1], conflicts => [] } }

1;

__END__

=head1 USAGE EXAMPLES

=head2 Edit Existing File

  [EDITOR:action=edit:target=<base64_file_path>:content=<base64_new_content>:options=<base64_options>]

=head2 Create New File from Template

  [EDITOR:action=create:target=<base64_target_spec>:content=<base64_content_spec>]
  
  Target JSON:
  {"file_path": "/path/to/new/file.pl"}
  
  Content JSON:
  {
    "template": "module",
    "template_data": {
      "module_name": "MyModule",
      "description": "My new module",
      "author": "Developer Name"
    }
  }

=head2 Refactor Code

  [EDITOR:action=refactor:target=<base64_file_path>:content=<base64_refactor_spec>]
  
  Content JSON:
  {
    "refactoring_operations": [
      {"type": "rename_function", "old_name": "oldFunc", "new_name": "newFunc"},
      {"type": "extract_method", "lines": "10-20", "new_method_name": "extractedMethod"}
    ]
  }

=head2 Format Code

  [EDITOR:action=format:target=<base64_file_path>:content=:options=<base64_options>]
  
  Options JSON:
  {
    "language": "perl",
    "write_file": true,
    "style": "standard"
  }

=head1 RETURN FORMAT

  {
    "success": true,
    "action": "edit",
    "file_path": "/path/to/file.pl",
    "changes_applied": true,
    "diff": "--- original\n+++ modified\n...",
    "original_size": 1234,
    "modified_size": 1456,
    "edit_strategy": "smart_replacement"
  }
1;
