package CLIO::Core::InstructionsReader;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use File::Spec;
use Cwd qw(getcwd);

=head1 NAME

CLIO::Core::InstructionsReader - Read custom instructions from .clio/instructions.md

=head1 DESCRIPTION

Reads project-specific instructions from .clio/instructions.md
to customize CLIO AI behavior per-project.

This enables per-project customization of:
- Development methodology (e.g., The Unbroken Method)
- Code standards and conventions
- Project-specific workflows
- Tool usage guidelines
- CLIO-specific behavior and preferences

Note: CLIO uses .clio/instructions.md (separate from VSCode's .github/copilot-instructions.md)
to avoid conflicts between different AI tools.

=head1 SYNOPSIS

    use CLIO::Core::InstructionsReader;
    
    my $reader = CLIO::Core::InstructionsReader->new(debug => 1);
    my $instructions = $reader->read_instructions('/path/to/project');
    
    if ($instructions) {
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
    
    # Default to current working directory if not provided
    $workspace_path ||= getcwd();
    
    # Build path to .clio/instructions.md
    my $instructions_file = File::Spec->catfile(
        $workspace_path,
        '.clio',
        'instructions.md'
    );
    
    print STDERR "[DEBUG][InstructionsReader] Checking for instructions at: $instructions_file\n"
        if $self->{debug};
    
    # Check if file exists
    unless (-f $instructions_file) {
        print STDERR "[DEBUG][InstructionsReader] No instructions file found\n"
            if $self->{debug};
        return undef;
    }
    
    # Read file contents
    my $content = eval {
        open my $fh, '<:encoding(UTF-8)', $instructions_file
            or die "Cannot open $instructions_file: $!";
        
        local $/; # slurp mode
        my $data = <$fh>;
        close $fh;
        
        return $data;
    };
    
    if ($@) {
        print STDERR "[ERROR][InstructionsReader] Failed to read instructions file: $@\n";
        return undef;
    }
    
    # Trim whitespace
    $content =~ s/^\s+|\s+$//g if defined $content;
    
    if (!$content || length($content) == 0) {
        print STDERR "[DEBUG][InstructionsReader] Instructions file is empty\n"
            if $self->{debug};
        return undef;
    }
    
    print STDERR "[DEBUG][InstructionsReader] Successfully loaded instructions (" 
        . length($content) . " bytes)\n"
        if $self->{debug};
    
    return $content;
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

1;

__END__

=head1 IMPLEMENTATION NOTES

This module manages CLIO-specific custom instructions, keeping them separate
from VSCode Copilot Chat instructions.

Key patterns:
- Path: .clio/instructions.md (CLIO-specific)
- Read as UTF-8 text
- Inject into system prompt
- Return undef if file doesn't exist (graceful degradation)
- Used by PromptManager->_load_custom_instructions()

The .clio directory can also contain other CLIO configuration files in the future.

Why separate from .github/copilot-instructions.md?
- Different AI tools (CLIO vs VSCode Copilot) have different capabilities
- Different system prompts and tool availability
- Instructions written for one tool may not work correctly in the other
- Allows developers to have tool-specific instructions without conflicts

Future enhancements:
- Support .clio/instructions/ folder with multiple .md files
- Support personal skill folders (.clio/skills)
- Cache instructions per session (don't re-read every message)
- Validate instructions syntax
