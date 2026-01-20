package CLIO::Core::SkillManager;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use JSON::PP qw(encode_json decode_json);
use File::Spec;
use File::Path qw(make_path);

=head1 NAME

CLIO::Core::SkillManager - Manage custom skills with variable substitution

=head1 DESCRIPTION

CLIO's prompt management system allows users to create, store, and use 
custom skills for common tasks. Supports variable substitution, JSON storage,
and user/project/session-level prompt hierarchies.

=head1 SYNOPSIS

    my $pm = CLIO::Core::SkillManager->new(
        debug => 1,
        session_skills_file => 'sessions/abc123/skills.json'
    );
    
    # Add custom skill
    $pm->add_skill('code-review', 'Review this code: ${code}');
    
    # Execute prompt with context
    my $result = $pm->execute_skill('code-review', { code => $code_content });
    print $result->{rendered_prompt};

=cut

# Built-in skills (read-only)
our %BUILTIN_PROMPTS = (
    explain => {
        name => 'explain',
        description => 'Explain selected code',
        prompt => 'Explain what this code does in clear, simple terms:

${code}',
        variables => ['code'],
        type => 'builtin',
        readonly => 1
    },
    review => {
        name => 'review',
        description => 'Review code for issues',
        prompt => 'Review this code for:
- Security issues
- Performance problems
- Best practices
- Edge cases

${code}',
        variables => ['code'],
        type => 'builtin',
        readonly => 1
    },
    test => {
        name => 'test',
        description => 'Generate comprehensive tests',
        prompt => 'Generate comprehensive tests for:

${code}

Use Test::More framework.
Include:
- Normal cases
- Edge cases
- Error handling
- Input validation',
        variables => ['code'],
        type => 'builtin',
        readonly => 1
    },
    fix => {
        name => 'fix',
        description => 'Propose fixes for problems',
        prompt => 'Analyze and fix problems in this code:

${code}

Problems detected:
${errors}

Provide:
1. Clear explanation of each problem
2. Proposed fix for each issue
3. Complete corrected code',
        variables => ['code', 'errors'],
        type => 'builtin',
        readonly => 1
    },
    doc => {
        name => 'doc',
        description => 'Generate documentation',
        prompt => 'Generate comprehensive documentation for:

${code}

Format: POD

Include:
- Module/function overview
- Parameter descriptions with types
- Return value documentation
- Usage examples
- Edge cases and error handling',
        variables => ['code'],
        type => 'builtin',
        readonly => 1
    }
);

=head2 new

Create a new SkillManager instance.

Arguments:
- debug: Enable debug output (optional)
- user_skills_file: Path to user-level skills.json (optional)
- project_skills_file: Path to project-level skills.json (optional)
- session_skills_file: Path to session-level skills.json (optional)

Returns: SkillManager instance

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        debug => $opts{debug} || 0,
        user_skills_file => $opts{user_skills_file} || 
            File::Spec->catfile($ENV{HOME}, '.clio', 'skills.json'),
        project_skills_file => $opts{project_skills_file} ||
            File::Spec->catfile('.clio', 'skills.json'),
        session_skills_file => $opts{session_skills_file},
        skills => {},
        active_prompt => undef,
    };
    
    bless $self, $class;
    $self->_load_skills();
    return $self;
}

=head2 _load_skills

Load skills from built-in definitions and JSON files.
Priority: Session > Project > User > Built-in

=cut

sub _load_skills {
    my ($self) = @_;
    
    # Load built-in skills first (lowest priority)
    $self->{skills} = { %BUILTIN_PROMPTS };
    
    # Load user skills (low priority)
    if (-f $self->{user_skills_file}) {
        my $user_prompts = $self->_read_skills_file($self->{user_skills_file});
        %{$self->{skills}} = (%{$self->{skills}}, %$user_prompts);
    }
    
    # Load project skills (medium priority)
    if (-f $self->{project_skills_file}) {
        my $project_prompts = $self->_read_skills_file($self->{project_skills_file});
        %{$self->{skills}} = (%{$self->{skills}}, %$project_prompts);
    }
    
    # Load session skills (highest priority)
    if ($self->{session_skills_file} && -f $self->{session_skills_file}) {
        my $session_prompts = $self->_read_skills_file($self->{session_skills_file});
        %{$self->{skills}} = (%{$self->{skills}}, %$session_prompts);
    }
    
    print STDERR "[DEBUG][SkillManager] Loaded " . scalar(keys %{$self->{skills}}) . " skills\n"
        if $self->{debug};
}

=head2 _read_skills_file

Read and parse a skills.json file.

Arguments:
- $file: Path to JSON file

Returns: Hashref of skills

=cut

sub _read_skills_file {
    my ($self, $file) = @_;
    
    open my $fh, '<', $file or return {};
    my $json = do { local $/; <$fh> };
    close $fh;
    
    my $data = eval { decode_json($json) };
    if ($@) {
        print STDERR "[ERROR][SkillManager] Failed to parse $file: $@\n";
        return {};
    }
    
    return {} unless $data && $data->{skills};
    
    return $data->{skills};
}

=head2 add_skill

Add a new custom skill.

Arguments:
- $name: Skill name (alphanumeric, hyphens, underscores)
- $prompt_text: Skill template with ${variables}
- %opts: Optional parameters (description, tags)

Returns: { success => 1, prompt => $prompt } or { success => 0, error => $msg }

=cut

sub add_skill {
    my ($self, $name, $prompt_text, %opts) = @_;
    
    # Validate name
    unless ($name =~ /^[a-zA-Z0-9_-]+$/) {
        return { 
            success => 0, 
            error => "Invalid prompt name (alphanumeric, hyphens, underscores only)" 
        };
    }
    
    # Check for builtin conflict
    if ($BUILTIN_PROMPTS{$name}) {
        return { 
            success => 0, 
            error => "Cannot override builtin prompt '$name'" 
        };
    }
    
    # Validate prompt text
    unless ($prompt_text) {
        return {
            success => 0,
            error => "Prompt text cannot be empty"
        };
    }
    
    # Extract variables from prompt
    my @variables = $self->_extract_variables($prompt_text);
    
    my $prompt = {
        name => $name,
        description => $opts{description} || "Custom skill",
        prompt => $prompt_text,
        variables => \@variables,
        type => 'custom',
        created => time(),
        modified => time(),
        usage_count => 0,
        tags => $opts{tags} || []
    };
    
    $self->{skills}{$name} = $prompt;
    $self->_save_skills();
    
    print STDERR "[DEBUG][SkillManager] Added prompt '$name' with variables: " . 
        join(", ", @variables) . "\n" if $self->{debug};
    
    return { success => 1, prompt => $prompt };
}

=head2 delete_skill

Delete a custom skill.

Arguments:
- $name: Skill name

Returns: { success => 1 } or { success => 0, error => $msg }

=cut

sub delete_skill {
    my ($self, $name) = @_;
    
    unless ($self->{skills}{$name}) {
        return { 
            success => 0, 
            error => "Skill '$name' not found" 
        };
    }
    
    if ($self->{skills}{$name}{type} eq 'builtin') {
        return { 
            success => 0, 
            error => "Cannot delete builtin prompt" 
        };
    }
    
    delete $self->{skills}{$name};
    $self->_save_skills();
    
    print STDERR "[DEBUG][SkillManager] Deleted prompt '$name'\n" if should_log('DEBUG');
    
    return { success => 1 };
}

=head2 get_skill

Retrieve a prompt by name.

Arguments:
- $name: Skill name

Returns: Skill hashref or undef if not found

=cut

sub get_skill {
    my ($self, $name) = @_;
    
    return $self->{skills}{$name};
}

=head2 list_skills

List all available skills.

Returns: { custom => [@names], builtin => [@names], all => [@names] }

=cut

sub list_skills {
    my ($self) = @_;
    
    my @custom = grep { $self->{skills}{$_}{type} eq 'custom' } keys %{$self->{skills}};
    my @builtin = grep { $self->{skills}{$_}{type} eq 'builtin' } keys %{$self->{skills}};
    
    return {
        custom => \@custom,
        builtin => \@builtin,
        all => [keys %{$self->{skills}}]
    };
}

=head2 execute_skill

Execute a prompt by substituting variables with context values.

Arguments:
- $name: Skill name
- $context: Hashref of variable values

Returns: { success => 1, rendered_prompt => $text, prompt => $prompt } 
         or { success => 0, error => $msg }

=cut

sub execute_skill {
    my ($self, $name, $context) = @_;
    
    my $prompt = $self->get_skill($name);
    unless ($prompt) {
        return { 
            success => 0, 
            error => "Skill '$name' not found" 
        };
    }
    
    # Substitute variables
    my $rendered = $self->_substitute_variables($prompt->{prompt}, $context);
    
    # Update usage count (only for custom skills)
    if ($prompt->{type} eq 'custom') {
        $prompt->{usage_count}++;
        $prompt->{modified} = time();
        $self->_save_skills();
    }
    
    print STDERR "[DEBUG][SkillManager] Executed prompt '$name'\n" if should_log('DEBUG');
    
    return {
        success => 1,
        rendered_prompt => $rendered,
        prompt => $prompt
    };
}

=head2 _substitute_variables

Substitute ${variables} in template with context values.

Arguments:
- $template: Template string with ${var} placeholders
- $context: Hashref of variable values

Returns: String with variables substituted

=cut

sub _substitute_variables {
    my ($self, $template, $context) = @_;
    
    my $result = $template;
    $context ||= {};
    
    # Simple variable substitution: ${var}
    while ($result =~ /\$\{([a-zA-Z0-9_:]+)\}/) {
        my $var = $1;
        my $value = $context->{$var};
        
        # Handle undefined variables
        $value = '' unless defined $value;
        
        # Escape special regex characters in value
        my $escaped_var = quotemeta($var);
        $result =~ s/\$\{$escaped_var\}/$value/g;
    }
    
    return $result;
}

=head2 _extract_variables

Extract all ${variables} from a template.

Arguments:
- $template: Template string

Returns: Array of variable names (unique)

=cut

sub _extract_variables {
    my ($self, $template) = @_;
    
    my @vars = ();
    my %seen = ();
    
    while ($template =~ /\$\{([a-zA-Z0-9_:]+)\}/g) {
        my $var = $1;
        unless ($seen{$var}) {
            push @vars, $var;
            $seen{$var} = 1;
        }
    }
    
    return @vars;
}

=head2 _save_skills

Save custom skills to user-level JSON file.

=cut

sub _save_skills {
    my ($self) = @_;
    
    # Only save custom skills to user file
    my %custom_prompts = map { 
        $_ => $self->{skills}{$_} 
    } grep { 
        $self->{skills}{$_}{type} eq 'custom' 
    } keys %{$self->{skills}};
    
    my $data = {
        version => '1.0',
        skills => \%custom_prompts,
        active_prompt => $self->{active_prompt},
        metadata => {
            last_updated => time(),
            total_prompts => scalar(keys %custom_prompts)
        }
    };
    
    # Ensure directory exists
    my ($volume, $dir, $file) = File::Spec->splitpath($self->{user_skills_file});
    my $full_dir = File::Spec->catpath($volume, $dir, '');
    make_path($full_dir) unless -d $full_dir;
    
    # Write JSON
    open my $fh, '>', $self->{user_skills_file} or do {
        print STDERR "[ERROR][SkillManager] Cannot write to $self->{user_skills_file}: $!\n";
        return;
    };
    print $fh encode_json($data);
    close $fh;
    
    print STDERR "[DEBUG][SkillManager] Saved " . scalar(keys %custom_prompts) . 
        " custom skills to $self->{user_skills_file}\n" if $self->{debug};
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

Copyright (c) 2026 CLIO Project

=cut
