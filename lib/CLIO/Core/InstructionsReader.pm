# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::InstructionsReader;

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug log_warning);
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
        log_debug('InstructionsReader', "Found CLIO_CUSTOM_INSTRUCTIONS env var: $custom_path");
        
        if (-f $custom_path) {
            log_debug('InstructionsReader', "Loading custom instructions from: $custom_path");
            
            open(my $fh, '<:encoding(UTF-8)', $custom_path) or do {
                log_debug('InstructionsReader', "Cannot read custom instructions file: $!");
                # Fall through to normal loading
                goto NORMAL_LOADING;
            };
            
            my $content = do { local $/; <$fh> };
            close($fh);
            
            if ($content) {
                log_debug('InstructionsReader', "Loaded " . length($content) . " bytes from custom instructions");
                return $content;
            }
        } else {
            log_debug('InstructionsReader', "CLIO_CUSTOM_INSTRUCTIONS file does not exist: $custom_path");
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
        log_debug('InstructionsReader', "Loaded .clio/instructions.md (" . length($clio_instructions) . " bytes)");
    }
    
    # 2. Load AGENTS.md (project-level context)
    # This provides domain knowledge and project-specific guidance
    my $agents_md = $self->_find_and_read_agents_md($workspace_path);
    if ($agents_md) {
        push @parts, $agents_md;
        log_debug('InstructionsReader', "Loaded AGENTS.md (" . length($agents_md) . " bytes)");
    }
    
    # Combine both sources (if any)
    if (@parts) {
        my $combined = join("\n\n---\n\n", @parts);
        log_debug('InstructionsReader', "Combined instructions: " . length($combined) . " bytes total");
        return $combined;
    }
    
    log_debug('InstructionsReader', "No custom instructions found");
    
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
    
    log_debug('InstructionsReader', "Checking for .clio/instructions.md at: $instructions_file");
    
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
        
        log_debug('InstructionsReader', "Checking for AGENTS.md at: $agents_file");
        
        if (-f $agents_file) {
            log_debug('InstructionsReader', "Found AGENTS.md at: $agents_file");
            return $self->_generate_agents_md_toc($agents_file);
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
    
    log_debug('InstructionsReader', "No AGENTS.md found in directory tree");
    
    return undef;
}

=head2 _generate_agents_md_toc

Generate a table-of-contents from AGENTS.md instead of returning the
full file content. AGENTS.md is a project-reference document that is
read on demand; sending its full content (~1000 lines) on every API
call wastes token budget and dilutes the system prompt. The TOC
provides section headers with line ranges so the model can read
specific sections on demand via file_operations.

Arguments:
- $file_path: Path to AGENTS.md

Returns:
- TOC string with section headers, line ranges, and extracted keywords

=cut

# Stop words used for keyword extraction. These are common English words
# that carry no semantic value for understanding a section's topic.
my %_KEYWORD_STOP_WORDS = map { $_ => 1 } qw(
    a an the and or but in on at to for of with by from is are was were be been
    being have has had do does did will would could should may might can must
    shall if then else when while during before after above below up down out off
    over under again further once here there what which who whom whose this these
    those are am i you he she it we they them us our their hers his theirs its
    your yours mine myself myself
    not no nor never more most some such only even also many much about across
    against all an any around as at away because before being below between both
    cannot couldn could did do does doing don't each few further had have having
    her here hers herself him himself his how i if in into is it its itself let's
    me might more most must my myself no nor not now of off on once one only or
    other our ours ourselves out over own same she should so some such than that
    the their theirs them themselves then there these they this those through to
    too under until up used very was we were what when where which while who
    whom why will with within without won't would wouldn't you your yours yourself
    yourselves ain't aren aren't couldn couldn't didn amn't aren't isn't ma might
    mustn't needn't shan't shouldn't wasn't weren weren't won't wouldn't above
    after again all also although always among another any around as at away
    be because been before being below between both but can could couldn't did
    do does don't down during each few for from further had hadn't has haven't
    have haven't having he her here hers herself him himself his how however i
    if in into is it its itself just let's me might more most must my myself no
    nor not now of off on once one only or other our ours ourselves out over
    own same shan't she should shouldn't so some such than that the their theirs
    them themselves then there these they this those through to too under unless
    until up used very was wasn't we were what when where which while who whom
    why will with within without won't would wouldn't you your yours herself
    himself itself one another shall
);

# Words commonly found in project reference docs that are context-specific
# but not useful as keywords for this purpose.
my %_KEYWORD_SKIP = map { $_ => 1 } qw(
    read write fix run test make build install config setup use using used
    see also note important table figure example examples section reference
    index the a an and or but to in on at for of with by from is are was
);

sub _generate_agents_md_toc {
    my ($self, $file_path) = @_;

    my $content = $self->_read_file($file_path);
    return undef unless $content && length $content;

    my @lines = split /\n/, $content;

    # Parse markdown headings to build the TOC. We track line numbers
    # for each heading so the model can read specific sections with
    # file_operations(start_line=N, end_line=M).
    #
    # We must skip headings inside code blocks (lines starting with #
    # inside ``` fences are bash comments, not markdown headings).
    my $line_num = 0;
    my $in_code_block = 0;
    my @headings;
    for my $line (@lines) {
        $line_num++;
        # Track code block state
        if ($line =~ /^```/) {
            $in_code_block = !$in_code_block;
            next;
        }
        next if $in_code_block;
        # Parse markdown headings (level 2 and above - skip H1 titles)
        if ($line =~ /^(#{2,})\s+(.+)/) {
            my $level = length($1);
            my $title = $2;
            # Trim trailing whitespace
            $title =~ s/\s+$//;
            push @headings, { level => $level, title => $title, line => $line_num };
        }
    }

    return undef unless @headings;

    # Build the TOC with line ranges and keywords for each section.
    my $toc = "## AGENTS.md (Project Reference)\n\n";
    $toc .= "Project-specific conventions, commands, and architecture. ";
    $toc .= "Read relevant sections on demand using file_operations:\n\n";
    $toc .= "    file_operations(operation: \"read_file\", path: \"AGENTS.md\", start_line: N, end_line: M)\n\n";
    $toc .= "### Sections:\n\n";

    my $total_lines = scalar @lines;

    for my $i (0 .. $#headings) {
        my $h = $headings[$i];
        # End line: find the next heading at the same or higher level
        my $end_line;
        for my $j ($i + 1 .. $#headings) {
            if ($headings[$j]{level} <= $h->{level}) {
                $end_line = $headings[$j]{line} - 1;
                last;
            }
        }
        # If no higher-level heading follows, end at the last line
        $end_line //= $total_lines;

        # Extract keywords from the section content (between this heading
        # and the end of the section, excluding sub-sections).
        my @keywords = $self->_extract_keywords(\@lines, $h->{line} + 1, $end_line);

        # Indent only for sub-headings (level > 2)
        my $indent = '';
        if ($h->{level} > 2) {
            $indent = "  " x ($h->{level} - 2);
        }

        $toc .= sprintf("%s- %s (%d-%d)\n", $indent, $h->{title},
            $h->{line}, $end_line);

        # Append keywords if any were found
        if (@keywords) {
            $toc .= sprintf("%s  keywords: %s\n", $indent, join(', ', @keywords));
        }
    }

    $toc .= "\n_This is a reference index. Read specific sections when you need ";
    $toc .= "project details (build commands, code style, testing, architecture)._\n";

    log_debug('InstructionsReader', "Generated AGENTS.md TOC (" . length($toc) . " chars, " . scalar(@headings) . " sections)");
    return $toc;
}

=head2 _extract_keywords

Extract relevant keywords from a range of text lines. This performs
simple frequency-based keyword extraction:

1. Strip markdown formatting (code blocks, inline code, links)
2. Tokenize text into words
3. Filter out stop words and single characters
4. Count word frequencies
5. Return the top N words by frequency (those with count >= min_count)

This works across any AGENTS.md without project-specific dictionaries.

Arguments:
- $lines: Arrayref of all lines in the file
- $start_line: 1-indexed start line (inclusive, after the heading)
- $end_line: 1-indexed end line (inclusive)

Returns:
- Array of keyword strings, sorted by frequency (descending)

=cut

sub _extract_keywords {
    my ($self, $lines, $start_line, $end_line) = @_;

    return () unless $lines && @$lines && $start_line && $end_line;

    # Clamp to valid range
    $start_line = 1 if $start_line < 1;
    $end_line = scalar(@$lines) if $end_line > scalar(@$lines);
    return () if $start_line > $end_line;

    my $in_code_block = 0;
    my %word_freq;

    for my $i ($start_line - 1 .. $end_line - 1) {
        last if $i >= @$lines;
        my $line = $lines->[$i];

        # Track code block state - skip content inside code blocks
        if ($line =~ /^```/) {
            $in_code_block = !$in_code_block;
            next;
        }
        next if $in_code_block;

        # Strip markdown inline code
        $line =~ s/`[^`]*`//g;
        # Strip markdown links: [text](url) -> text
        $line =~ s/\[([^\]]+)\]\([^)]+\)/$1/g;
        # Strip markdown tables
        next if $line =~ /^\s*\|/;
        # Strip markdown list markers
        $line =~ s/^\s*[-*+]\s+//;
        $line =~ s/^\s*\d+\.\s+//;
        # Strip markdown bold/italic
        $line =~ s/\*{1,2}([^*]+)\*{1,2}/$1/g;
        $line =~ s/_([^_]+)_/$1/g;

        # Tokenize: extract word tokens
        while ($line =~ /([A-Za-z][A-Za-z0-9_-]+)/g) {
            my $word = lc($1);

            # Skip short words and stop words
            next if length($word) < 4;
            next if exists $_KEYWORD_STOP_WORDS{$word};
            next if exists $_KEYWORD_SKIP{$word};

            $word_freq{$word}++;
        }
    }

    return () unless %word_freq;

    # Sort by frequency (descending), then alphabetically for stability
    my @sorted = sort {
        $word_freq{$b} <=> $word_freq{$a} || $a cmp $b
    } keys %word_freq;

    # Return top 8 keywords (those with frequency >= 2 get priority,
    # then fill remaining slots with single-occurrence words)
    my @keywords;

    # First pass: words appearing 2+ times
    for my $word (@sorted) {
        last if @keywords >= 8;
        if ($word_freq{$word} >= 2) {
            push @keywords, $word;
        }
    }

    # Second pass: fill remaining slots with single-occurrence words
    for my $word (@sorted) {
        last if @keywords >= 8;
        if ($word_freq{$word} == 1) {
            push @keywords, $word;
        }
    }

    return @keywords;
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
            or croak "Cannot open $file_path: $!";
        
        local $/; # slurp mode
        my $data = <$fh>;
        close $fh;
        
        return $data;
    };
    
    if ($@) {
        log_debug('InstructionsReader', "Failed to read file $file_path: $@");
        return undef;
    }
    
    # Trim whitespace
    $content =~ s/^\s+|\s+$//g if defined $content;
    
    if (!$content || length($content) == 0) {
        log_debug('InstructionsReader', "File is empty: $file_path");
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
