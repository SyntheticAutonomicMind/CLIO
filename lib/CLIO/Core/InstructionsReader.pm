package CLIO::Core::InstructionsReader;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use File::Spec;
use Cwd qw(getcwd);

=head1 NAME

CLIO::Core::InstructionsReader - Read custom instructions from .clio/instructions.md and AGENTS.md

=head1 DESCRIPTION

Reads project-specific instructions to customize CLIO AI behavior per-project.
Supports TWO instruction sources that are merged together:

1. **.clio/instructions.md** - CLIO-specific operational guidance
   - The Unbroken Method and other CLIO methodologies
   - CLIO tool usage patterns
   - Session handoff procedures
   - Collaboration checkpoint discipline
   - CLIO-specific behavior and preferences

2. **AGENTS.md** - Project-level context (https://agents.md/ standard)
   - Build and test commands
   - Code style and conventions
   - Project structure and architecture
   - Domain knowledge and context
   - Works across multiple AI coding tools

Both files are optional. If both exist, they are merged in this order:
1. .clio/instructions.md (CLIO operational identity)
2. AGENTS.md (project domain knowledge)

This allows projects to use the open AGENTS.md standard for general guidance
while adding CLIO-specific instructions in .clio/instructions.md.

Note: CLIO uses .clio/instructions.md (separate from VSCode's .github/copilot-instructions.md)
to avoid conflicts between different AI tools.

=head1 SYNOPSIS

    use CLIO::Core::InstructionsReader;
    
    my $reader = CLIO::Core::InstructionsReader->new(debug => 1);
    my $instructions = $reader->read_instructions('/path/to/project');
    
    if ($instructions) {
        # Contains merged content from both .clio/instructions.md and AGENTS.md
        print "Custom instructions:\n$instructions\n";
    }

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} || 0,
    };
    
    return bless $self, $class;
}

=head2 read_instructions

Read custom instructions from .clio/instructions.md if it exists.

Arguments:
- $workspace_path: Path to workspace root (optional, defaults to current directory)

Returns:
- Instructions content as string, or undef if file doesn't exist

=cut

sub read_instructions {
    my ($self, $workspace_path) = @_;
    
    # Check for environment variable override (used by sub-agents)
    my $custom_path = $ENV{CLIO_CUSTOM_INSTRUCTIONS};
    if ($custom_path) {
        print STDERR "[DEBUG][InstructionsReader] Found CLIO_CUSTOM_INSTRUCTIONS env var: $custom_path\n";
        
        if (-f $custom_path) {
            print STDERR "[DEBUG][InstructionsReader] Loading custom instructions from: $custom_path\n";
            
            open(my $fh, '<:encoding(UTF-8)', $custom_path) or do {
                print STDERR "[WARN][InstructionsReader] Cannot read custom instructions file: $!\n";
                # Fall through to normal loading
                goto NORMAL_LOADING;
            };
            
            my $content = do { local $/; <$fh> };
            close($fh);
            
            if ($content) {
                print STDERR "[DEBUG][InstructionsReader] Loaded " . length($content) . " bytes from custom instructions\n";
                return $content;
            }
        } else {
            print STDERR "[WARN][InstructionsReader] CLIO_CUSTOM_INSTRUCTIONS file does not exist: $custom_path\n";
        }
    }
    
    NORMAL_LOADING:
    # Default to current working directory if not provided
    $workspace_path ||= getcwd();
    
    my @parts;
    
    # 1. Load CLIO-specific instructions first (.clio/instructions.md)
    # This defines CLIO's operational identity and behavior
    my $clio_instructions = $self->_read_clio_instructions($workspace_path);
    if ($clio_instructions) {
        push @parts, $clio_instructions;
        print STDERR "[DEBUG][InstructionsReader] Loaded .clio/instructions.md (" 
            . length($clio_instructions) . " bytes)\n"
            if $self->{debug};
    }
    
    # 2. Load AGENTS.md (project-level context)
    # This provides domain knowledge and project-specific guidance
    my $agents_md = $self->_find_and_read_agents_md($workspace_path);
    if ($agents_md) {
        push @parts, $agents_md;
        print STDERR "[DEBUG][InstructionsReader] Loaded AGENTS.md (" 
            . length($agents_md) . " bytes)\n"
            if $self->{debug};
    }
    
    # Combine both sources (if any)
    if (@parts) {
        my $combined = join("\n\n---\n\n", @parts);
        print STDERR "[DEBUG][InstructionsReader] Combined instructions: " 
            . length($combined) . " bytes total\n"
            if $self->{debug};
        return $combined;
    }
    
    print STDERR "[DEBUG][InstructionsReader] No custom instructions found\n"
        if $self->{debug};
    
    return undef;
}

=head2 get_workspace_path

Get the workspace path from the current working directory.
Can be enhanced later to support multiple workspace folders.

Returns:
- Workspace root path

=cut

sub get_workspace_path {
    my ($self) = @_;
    
    # For now, just return the current working directory
    # In the future, could search upward for .git, package.json, etc.
    return getcwd();
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# INTERNAL METHODS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

=head2 _read_clio_instructions

Read CLIO-specific instructions from .clio/instructions.md.
This file contains CLIO's operational behavior and methodology.

Arguments:
- $workspace_path: Path to workspace root

Returns:
- Instructions content as string, or undef if file doesn't exist

=cut

sub _read_clio_instructions {
    my ($self, $workspace_path) = @_;
    
    # Build path to .clio/instructions.md
    my $instructions_file = File::Spec->catfile(
        $workspace_path,
        '.clio',
        'instructions.md'
    );
    
    print STDERR "[DEBUG][InstructionsReader] Checking for .clio/instructions.md at: $instructions_file\n"
        if $self->{debug};
    
    return $self->_read_file($instructions_file);
}

=head2 _find_and_read_agents_md

Find and read AGENTS.md by walking up the directory tree.
AGENTS.md is an open standard for AI agent instructions (https://agents.md/).
This provides project-level context that works across multiple AI tools.

Per AGENTS.md spec:
- Check current directory first
- Walk up parent directories until found
- Stop at filesystem root or when found
- Support for monorepos (closest AGENTS.md wins)

Arguments:
- $workspace_path: Starting path to search from

Returns:
- AGENTS.md content as string, or undef if not found

=cut

sub _find_and_read_agents_md {
    my ($self, $workspace_path) = @_;
    
    require File::Basename;
    
    my $current_dir = $workspace_path;
    my $max_depth = 10;  # Prevent infinite loops
    my $depth = 0;
    
    while ($depth < $max_depth) {
        my $agents_file = File::Spec->catfile($current_dir, 'AGENTS.md');
        
        print STDERR "[DEBUG][InstructionsReader] Checking for AGENTS.md at: $agents_file\n"
            if $self->{debug};
        
        if (-f $agents_file) {
            print STDERR "[DEBUG][InstructionsReader] Found AGENTS.md at: $agents_file\n"
                if $self->{debug};
            return $self->_read_file($agents_file);
        }
        
        # Move up to parent directory
        my $parent_dir = File::Basename::dirname($current_dir);
        
        # Stop if we've reached the root or can't go higher
        last if $parent_dir eq $current_dir;
        last if $parent_dir eq '/';
        last if $parent_dir =~ m{^[A-Z]:[/\\]$};  # Windows root
        
        $current_dir = $parent_dir;
        $depth++;
    }
    
    print STDERR "[DEBUG][InstructionsReader] No AGENTS.md found in directory tree\n"
        if $self->{debug};
    
    return undef;
}

=head2 _read_file

Read a file and return its contents, or undef if file doesn't exist or is empty.

Arguments:
- $file_path: Path to file to read

Returns:
- File content as string, or undef

=cut

sub _read_file {
    my ($self, $file_path) = @_;
    
    # Check if file exists
    unless (-f $file_path) {
        return undef;
    }
    
    # Read file contents
    my $content = eval {
        open my $fh, '<:encoding(UTF-8)', $file_path
            or die "Cannot open $file_path: $!";
        
        local $/; # slurp mode
        my $data = <$fh>;
        close $fh;
        
        return $data;
    };
    
    if ($@) {
        print STDERR "[ERROR][InstructionsReader] Failed to read file $file_path: $@\n" if should_log('ERROR');
        return undef;
    }
    
    # Trim whitespace
    $content =~ s/^\s+|\s+$//g if defined $content;
    
    if (!$content || length($content) == 0) {
        print STDERR "[DEBUG][InstructionsReader] File is empty: $file_path\n"
            if $self->{debug};
        return undef;
    }
    
    return $content;
}

1;

__END__

=head1 IMPLEMENTATION NOTES

This module manages both CLIO-specific instructions and AGENTS.md support.

Key patterns:
- Paths: .clio/instructions.md (CLIO-specific) + AGENTS.md (standard)
- Read as UTF-8 text
- Merge both sources with separator
- Inject into system prompt via PromptManager
- Return undef if neither file exists (graceful degradation)
- AGENTS.md is found by walking up directory tree (monorepo support)

=head2 Why Support Both?

**.clio/instructions.md:**
- CLIO operational behavior (how CLIO works as an agent)
- The Unbroken Method and other CLIO-specific methodologies
- CLIO tool usage patterns and preferences
- Session management and handoff procedures

**AGENTS.md:**
- Open standard supported by 60k+ projects and 20+ AI tools
- Project-level context (build commands, test procedures, code style)
- Domain knowledge and architecture
- Works with Cursor, Aider, Copilot, Jules, etc.

By supporting both, CLIO gets:
- Standards compliance (AGENTS.md ecosystem)
- CLIO-enhanced capabilities (.clio/instructions.md)
- Best of both worlds for users

=head2 Why .clio/instructions.md separate from VSCode .github/copilot-instructions.md?

- Different AI tools (CLIO vs VSCode Copilot) have different capabilities
- Different system prompts and tool availability
- Instructions written for one tool may not work correctly in the other
- Allows developers to have tool-specific instructions without conflicts

=head2 Order of Merging

1. .clio/instructions.md (identity - who CLIO is, how it operates)
2. AGENTS.md (domain - what CLIO is working on, project context)

This ensures CLIO's foundational behavior is established before adding
project-specific knowledge.

=head2 Future Enhancements

- Support .clio/instructions/ folder with multiple .md files
- Support personal skill folders (.clio/skills)
- Cache instructions per session (don't re-read every message)
- Validate instructions syntax
- Support AGENTS.md variables and templating
1;
