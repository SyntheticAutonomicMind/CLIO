package CLIO::Tools::CodeIntelligence;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(should_log log_debug);
use parent 'CLIO::Tools::Tool';
use File::Find;
use Cwd 'abs_path';

=head1 NAME

CLIO::Tools::CodeIntelligence - Code analysis, symbol search, and history search tool

=head1 DESCRIPTION

Provides code intelligence operations for finding symbol usages, definitions,
references, and semantic search through git commit history.

Operations:
  list_usages    - Find all usages of a symbol across the codebase
  search_history - Semantic search through git commit messages and history

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
    
    # Search git history semantically
    my $history = $tool->execute(
        {
            operation => 'search_history',
            query => 'authentication refactoring',
            max_results => 10
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

-  search_history - Semantic search through git commit messages
  Parameters:
    - query (required): Natural language search query (e.g., "authentication fixes", "refactored error handling")
    - max_results (optional): Maximum commits to return (default: 20)
    - since (optional): Only search commits after this date (YYYY-MM-DD format)
    - author (optional): Filter by commit author name/email
  Returns: Ranked list of commits matching the query by relevance
  
  WHEN TO USE search_history:
  - User asks about past work: "what did we do about X?", "when did we fix Y?"
  - Before implementing: check if similar work was done before
  - Understanding context: "why was this changed?", "what was the original approach?"
  - Finding related commits: "show me commits about authentication"
  - Avoiding duplicate work: search before starting a new feature
  
  Note: Uses keyword extraction and scoring to find semantically relevant commits.
        Searches both commit subjects and bodies. Much better than grep for
        natural language queries about project history.
},
        supported_operations => [qw(
            list_usages
            search_history
        )],
        %opts,
    );
    
    return $self;
}

sub route_operation {
    my ($self, $operation, $params, $context) = @_;
    
    if ($operation eq 'list_usages') {
        return $self->list_usages($params, $context);
    } elsif ($operation eq 'search_history') {
        return $self->search_history($params, $context);
    }
    
    return $self->error_result("Operation not implemented: $operation");
}

=head2 get_additional_parameters

Define parameters for code_intelligence in JSON schema sent to AI.

=cut

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        # list_usages parameters
        symbol_name => {
            type => "string",
            description => "Symbol to search for (required for list_usages)",
        },
        file_paths => {
            type => "array",
            items => { type => "string" },
            description => "Array of paths to search in (optional, default: current directory)",
        },
        context_lines => {
            type => "integer",
            description => "Number of context lines around match (optional, default: 0)",
        },
        
        # search_history parameters
        query => {
            type => "string",
            description => "Natural language search query for git history (required for search_history). Examples: 'authentication fixes', 'refactored error handling', 'performance improvements'",
        },
        max_results => {
            type => "integer",
            description => "Maximum number of commits to return (optional, default: 20)",
        },
        since => {
            type => "string",
            description => "Only search commits after this date, YYYY-MM-DD format (optional)",
        },
        author => {
            type => "string",
            description => "Filter by commit author name or email (optional)",
        },
    };
}

=head2 search_history

Semantic search through git commit messages and history.

Uses keyword extraction and scoring to find commits that semantically match
the query, even if exact words don't match.

Parameters:
- query: Natural language search query (required)
- max_results: Maximum commits to return (optional, default: 20)
- since: Only search commits after this date (optional, YYYY-MM-DD)
- author: Filter by author name/email (optional)

Returns: Hash with:
- success: Boolean
- message: Summary message
- commits: Array of {hash, date, author, subject, body, score, files_changed}
- count: Total matches found
- keywords: Keywords extracted from query

=cut

sub search_history {
    my ($self, $params, $context) = @_;
    
    my $query = $params->{query};
    my $max_results = $params->{max_results} || 20;
    my $since = $params->{since};
    my $author = $params->{author};
    
    return $self->error_result("Missing 'query' parameter",
        action_description => "Error: Missing 'query' parameter"
    ) unless $query;
    
    # Check if we're in a git repo
    unless ($self->_has_git_grep()) {
        return $self->error_result("Not in a git repository",
            action_description => "Error: Not in a git repository"
        );
    }
    
    log_debug('CodeIntelligence', "Searching history for: $query");
    
    # Extract keywords from query (words > 2 chars, lowercase)
    my @keywords = grep { length($_) > 2 } split(/\W+/, lc($query));
    
    unless (@keywords) {
        return $self->error_result("No valid search keywords in query");
    }
    
    print STDERR "[DEBUG][CodeIntelligence] Keywords: " . join(', ', @keywords) . "\n" if should_log('DEBUG');
    
    # Fetch commits from git log
    my @commits = $self->_fetch_commits($since, $author);
    
    print STDERR "[DEBUG][CodeIntelligence] Fetched " . scalar(@commits) . " commits\n" if should_log('DEBUG');
    
    if (@commits == 0) {
        return $self->success_result(
            "No commits found matching filters",
            action_description => "searching git history (0 commits)",
            commits => [],
            count => 0,
            keywords => \@keywords,
        );
    }
    
    # Score each commit based on keyword matches
    my @scored_commits = ();
    
    foreach my $commit (@commits) {
        my $score = $self->_score_commit($commit, \@keywords);
        
        if ($score > 0) {
            $commit->{score} = $score;
            push @scored_commits, $commit;
        }
    }
    
    # Sort by score (descending), then by date (newer first)
    @scored_commits = sort { 
        $b->{score} <=> $a->{score} || 
        $b->{date} cmp $a->{date}
    } @scored_commits;
    
    my $total_matches = scalar(@scored_commits);
    
    # Limit results
    if (@scored_commits > $max_results) {
        @scored_commits = splice(@scored_commits, 0, $max_results);
    }
    
    # Fetch files changed for top results (expensive, so only do for returned results)
    foreach my $commit (@scored_commits) {
        $commit->{files_changed} = $self->_get_files_changed($commit->{hash});
    }
    
    my $message = "Found $total_matches commits matching '$query'";
    $message .= " (showing top $max_results)" if $total_matches > $max_results;
    
    my $action_desc = "searching git history for '$query' ($total_matches matches)";
    
    print STDERR "[DEBUG][CodeIntelligence] Returning " . scalar(@scored_commits) . " results\n" if should_log('DEBUG');
    
    return $self->success_result(
        $message,
        action_description => $action_desc,
        commits => \@scored_commits,
        count => $total_matches,
        keywords => \@keywords,
        showing => scalar(@scored_commits),
    );
}

=head2 _fetch_commits

Fetch commits from git log with optional filters.

=cut

sub _fetch_commits {
    my ($self, $since, $author) = @_;
    
    # Build git log command
    # Format: hash|date|author|subject|body (use | as delimiter since it's unlikely in commits)
    my $format = '%H|%aI|%an <%ae>|%s|%b%x00';  # %x00 = null byte as record separator
    
    my @cmd_parts = ('git', 'log', "--format=$format");
    
    # Add optional filters
    if ($since) {
        push @cmd_parts, "--since=$since";
    }
    if ($author) {
        push @cmd_parts, "--author=$author";
    }
    
    # Limit to reasonable number of commits to search (can be a lot!)
    push @cmd_parts, '-n', '500';
    
    my $cmd = join(' ', map { quotemeta($_) } @cmd_parts) . ' 2>/dev/null';
    
    log_debug('CodeIntelligence', "Running: $cmd");
    
    my $output = `$cmd`;
    return () unless $output;
    
    # Parse commits (split by null byte)
    my @raw_commits = split(/\x00/, $output);
    my @commits = ();
    
    foreach my $raw (@raw_commits) {
        $raw =~ s/^\s+|\s+$//g;  # Trim
        next unless $raw;
        
        # Split by | (but only first 4 pipes, body may contain |)
        my @parts = split(/\|/, $raw, 5);
        next unless @parts >= 4;
        
        my ($hash, $date, $author_info, $subject, $body) = @parts;
        $body //= '';
        $body =~ s/^\s+|\s+$//g;
        
        push @commits, {
            hash => $hash,
            short_hash => substr($hash, 0, 8),
            date => $date,
            author => $author_info,
            subject => $subject,
            body => $body,
        };
    }
    
    return @commits;
}

=head2 _score_commit

Score a commit based on keyword matches.

Scoring:
- Subject match: +3 per keyword
- Body match: +1 per keyword
- Exact phrase match in subject: +5 bonus
- Multiple keyword matches: multiplicative bonus

=cut

sub _score_commit {
    my ($self, $commit, $keywords) = @_;
    
    my $score = 0;
    my $subject_lc = lc($commit->{subject} || '');
    my $body_lc = lc($commit->{body} || '');
    my $full_text = "$subject_lc $body_lc";
    
    my $subject_matches = 0;
    my $body_matches = 0;
    
    foreach my $keyword (@$keywords) {
        # Subject matches (higher weight)
        if ($subject_lc =~ /\Q$keyword\E/) {
            $score += 3;
            $subject_matches++;
        }
        
        # Body matches (lower weight)
        if ($body_lc =~ /\Q$keyword\E/) {
            $score += 1;
            $body_matches++;
        }
    }
    
    # Bonus for multiple keywords matching
    my $total_keyword_matches = $subject_matches + $body_matches;
    if ($total_keyword_matches >= 2) {
        $score += $total_keyword_matches;  # Bonus for relevance
    }
    
    # Bonus for matching most/all keywords
    my $keyword_coverage = ($subject_matches + $body_matches) / (scalar(@$keywords) * 2);
    if ($keyword_coverage >= 0.5) {
        $score += 3;  # Good coverage bonus
    }
    
    return $score;
}

=head2 _get_files_changed

Get list of files changed in a commit.

=cut

sub _get_files_changed {
    my ($self, $hash) = @_;
    
    my $cmd = "git show --name-only --format='' " . quotemeta($hash) . " 2>/dev/null";
    my $output = `$cmd`;
    
    return [] unless $output;
    
    my @files = grep { $_ } split(/\n/, $output);
    return \@files;
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
    
    return $self->error_result("Missing 'symbol_name' parameter", 
        action_description => "Error: Missing 'symbol_name' parameter"
    ) unless $symbol_name;
    return $self->error_result("'file_paths' must be an array") 
        unless ref($file_paths) eq 'ARRAY';
    
    log_debug('CodeIntelligence', "Searching for symbol: $symbol_name");
    print STDERR "[DEBUG][CodeIntelligence] Search paths: " . join(', ', @$file_paths) . "\n" if should_log('DEBUG');
    
    my @usages = ();
    
    # Try git grep first (much faster if in a git repo)
    if ($self->_has_git_grep()) {
        @usages = $self->_git_grep_search($symbol_name, $file_paths, $context_lines);
    } else {
        @usages = $self->_file_grep_search($symbol_name, $file_paths, $context_lines);
    }
    
    my $count = scalar(@usages);
    
    log_debug('CodeIntelligence', "Found $count usages");
    
    if ($count == 0) {
        my $action_desc = "searching for symbol '$symbol_name' (found 0 usages)";
        return {
            success => 1,
            output => "No usages found for '$symbol_name'",
            action_description => $action_desc,
            tool_name => 'code_intelligence',
            usages => [],
            count => 0,
            symbol => $symbol_name,
        };
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
    
    log_debug('CodeIntelligence', "Running: $cmd");
    
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
