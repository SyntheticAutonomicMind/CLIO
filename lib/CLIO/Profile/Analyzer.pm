package CLIO::Profile::Analyzer;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(log_debug log_warning log_error);
use CLIO::Util::JSON qw(decode_json);
use File::Spec;
use Cwd qw(getcwd);

=head1 NAME

CLIO::Profile::Analyzer - Analyze session history to build user personality profiles

=head1 DESCRIPTION

Scans CLIO session history across all projects to extract communication
patterns, working preferences, and interaction style. Used by /profile build
to feed statistical data and sample messages to the AI for collaborative
profile generation.

The Analyzer collects quantitative data (style counters, topic frequencies)
and qualitative data (sample messages). It does NOT attempt to synthesize
these into profile text - that's the AI's job during the interactive
/profile build flow.

=cut

sub new {
    my ($class, %args) = @_;
    return bless {
        debug => $args{debug} || 0,
    }, $class;
}

=head2 analyze_sessions

Scan all available session files and extract user interaction patterns.

Arguments:
- $search_paths: Arrayref of paths to search for .clio/sessions/ directories
                 Defaults to current directory, sibling repos, and home .clio/

Returns:
- Hashref with analysis results:
  - total_sessions: number of session files processed
  - total_user_msgs: number of user messages analyzed
  - projects: { name => { sessions, user_msgs } }
  - style: { pattern_name => count }
  - topics: { keyword => count }
  - user_messages: sample messages (capped at 200)

=cut

sub analyze_sessions {
    my ($self, $search_paths) = @_;

    $search_paths ||= $self->_default_search_paths();

    my @session_files = $self->_find_session_files($search_paths);

    log_debug('ProfileAnalyzer', "Found " . scalar(@session_files) . " session files");

    my %results = (
        total_sessions    => 0,
        total_user_msgs   => 0,
        projects          => {},
        style             => {},
        topics            => {},
        user_messages     => [],
    );

    for my $file (sort @session_files) {
        $self->_analyze_session_file($file, \%results);
    }

    return \%results;
}

=head2 generate_profile_draft

Generate a statistical summary from analysis results for AI consumption.

This produces a data-oriented summary, not a finished profile. The AI uses
this alongside sample messages to collaboratively build the actual profile
with the user.

Arguments:
- $analysis: Hashref from analyze_sessions()

Returns:
- String containing formatted analysis summary

=cut

sub generate_profile_draft {
    my ($self, $analysis) = @_;

    my $style = $analysis->{style} || {};
    my $total = $analysis->{total_user_msgs} || 1;

    my @sections;

    # Communication patterns with percentages
    my @comm_stats;
    my @comm_keys = qw(
        collaborative_language short_messages medium_messages
        long_detailed_messages concise_approvals states_desires
        corrections_redirects positive_feedback asks_questions
        provides_context uses_humor frustration_signals
    );
    for my $key (@comm_keys) {
        my $count = $style->{$key} || 0;
        next unless $count > 0;
        my $pct = sprintf("%.0f%%", 100 * $count / $total);
        (my $label = $key) =~ s/_/ /g;
        push @comm_stats, "$label: $count ($pct)";
    }
    if (@comm_stats) {
        push @sections, "**Communication patterns:** " . join(', ', @comm_stats);
    }

    # Working style patterns
    my @work_stats;
    my @work_keys = qw(
        bug_reports includes_code shares_urls strategic_thinking
        tactical_directives delegates_high_level micromanages_details
        adds_requirements_iteratively references_past_work
        learning_exploring
    );
    for my $key (@work_keys) {
        my $count = $style->{$key} || 0;
        next unless $count > 0;
        my $pct = sprintf("%.0f%%", 100 * $count / $total);
        (my $label = $key) =~ s/_/ /g;
        push @work_stats, "$label: $count ($pct)";
    }
    if (@work_stats) {
        push @sections, "**Working style indicators:** " . join(', ', @work_stats);
    }

    # Behavioral signals
    my @behavior_stats;
    my @behavior_keys = qw(
        urgency_signals patience_signals quality_focus grants_autonomy
    );
    for my $key (@behavior_keys) {
        my $count = $style->{$key} || 0;
        next unless $count > 0;
        my $pct = sprintf("%.0f%%", 100 * $count / $total);
        (my $label = $key) =~ s/_/ /g;
        push @behavior_stats, "$label: $count ($pct)";
    }
    if (@behavior_stats) {
        push @sections, "**Behavioral signals:** " . join(', ', @behavior_stats);
    }

    # Technology topics (sorted by frequency)
    my @techs;
    my $topics = $analysis->{topics} || {};
    for my $tech (sort { ($topics->{$b} || 0) <=> ($topics->{$a} || 0) } keys %$topics) {
        last if @techs >= 15;
        next if ($topics->{$tech} || 0) < 2;
        push @techs, "$tech ($topics->{$tech})";
    }
    if (@techs) {
        push @sections, "**Technologies mentioned:** " . join(', ', @techs);
    }

    # Active projects
    my @projects;
    my $proj_data = $analysis->{projects} || {};
    for my $p (sort { ($proj_data->{$b}{user_msgs} || 0) <=> ($proj_data->{$a}{user_msgs} || 0) } keys %$proj_data) {
        last if @projects >= 8;
        next if ($proj_data->{$p}{user_msgs} || 0) < 2;
        push @projects, "$p ($proj_data->{$p}{user_msgs} msgs)";
    }
    if (@projects) {
        push @sections, "**Active projects:** " . join(', ', @projects);
    }

    my $draft = "## Analysis Summary\n\n";
    $draft .= join("\n\n", @sections);
    $draft .= "\n";

    return $draft;
}

=head2 get_session_count

Quick count of available sessions without full analysis.

Returns:
- Number of session files found

=cut

sub get_session_count {
    my ($self) = @_;

    my $paths = $self->_default_search_paths();
    my @files = $self->_find_session_files($paths);

    return scalar @files;
}

=head2 _find_session_files

Efficiently find session JSON files by looking directly in .clio/sessions/ directories.
Does not use File::Find to avoid recursing into large project trees.

=cut

sub _find_session_files {
    my ($self, $search_paths) = @_;

    my @session_files;
    my %seen;
    my %seen_dirs;

    for my $base (@$search_paths) {
        next unless -d $base;
        $self->_scan_for_sessions($base, \@session_files, \%seen, \%seen_dirs, 0);
    }

    return @session_files;
}

sub _scan_for_sessions {
    my ($self, $dir, $files, $seen, $seen_dirs, $depth) = @_;

    return if $depth > 4;  # Max recursion depth
    return if $seen_dirs->{$dir}++;

    # Check for .clio/sessions/ in this directory
    my $sessions_dir = File::Spec->catdir($dir, '.clio', 'sessions');
    if (-d $sessions_dir) {
        if (opendir(my $dh, $sessions_dir)) {
            while (my $entry = readdir($dh)) {
                next unless $entry =~ /\.json$/ && $entry ne 'todos.json';
                my $path = File::Spec->catfile($sessions_dir, $entry);
                next if $seen->{$path}++;
                push @$files, $path;
            }
            closedir($dh);
        }
    }

    # For home directory, don't recurse (we only want ~/.clio/sessions/)
    my $home = $ENV{HOME} || '';
    return if $dir eq $home;

    # Recurse into subdirectories that have their own .clio/ directories
    if (opendir(my $dh, $dir)) {
        my @entries = readdir($dh);
        closedir($dh);

        for my $entry (@entries) {
            next if $entry =~ /^\./;
            next if $entry eq '.clio';
            next if $entry =~ /^(node_modules|__pycache__|build|dist|vendor|target|venv|\.build|Pods|DerivedData|python_env|lib|src)$/;
            my $subdir = File::Spec->catdir($dir, $entry);
            next unless -d $subdir;
            # Only recurse if this subdir has .clio/
            next unless -d File::Spec->catdir($subdir, '.clio');
            $self->_scan_for_sessions($subdir, $files, $seen, $seen_dirs, $depth + 1);
        }
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# INTERNAL METHODS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

sub _default_search_paths {
    my ($self) = @_;

    my @paths;

    # Current directory (project level)
    my $cwd = getcwd();
    push @paths, $cwd;

    # If we're in a repo collection, scan siblings for .clio/sessions/
    if ($cwd =~ m{^(.+)/[^/]+$}) {
        my $parent_dir = $1;
        if (opendir(my $dh, $parent_dir)) {
            while (my $entry = readdir($dh)) {
                next if $entry =~ /^\./;
                my $sibling = File::Spec->catdir($parent_dir, $entry);
                next unless -d $sibling;
                my $clio_dir = File::Spec->catdir($sibling, '.clio');
                next unless -d $clio_dir;
                push @paths, $sibling;
            }
            closedir($dh);
        }
    }

    # Home .clio/sessions/ directory (global sessions only - don't scan home recursively)
    my $home = $ENV{HOME} || '';
    my $home_sessions = File::Spec->catdir($home, '.clio', 'sessions');
    if (-d $home_sessions && !grep { $_ eq $home } @paths) {
        push @paths, $home;
    }

    log_debug('ProfileAnalyzer', "Search paths: " . scalar(@paths) . " directories");
    return \@paths;
}

sub _analyze_session_file {
    my ($self, $file, $results) = @_;

    # Skip very large files (>2MB) to keep analysis fast
    my $size = -s $file || 0;
    if ($size > 2_000_000) {
        log_debug('ProfileAnalyzer', "Skipping large session file ($size bytes): $file");
        return;
    }

    my $json_text;
    eval {
        open my $fh, '<', $file or die "Cannot open $file: $!";
        local $/;
        $json_text = <$fh>;
        close $fh;
    };
    if ($@ || !$json_text) {
        log_debug('ProfileAnalyzer', "Skipping unreadable file: $file");
        return;
    }

    my $data;
    eval { $data = decode_json($json_text) };
    if ($@) {
        log_debug('ProfileAnalyzer', "Skipping unparseable file: $file");
        return;
    }

    $results->{total_sessions}++;

    # Extract project name from path
    my $project = $file;
    if ($file =~ m{/([^/]+)/\.clio/sessions/}) {
        $project = $1;
    } else {
        $project = '(global)';
    }

    $results->{projects}{$project}{sessions}++;

    my $history = $data->{history} || $data->{messages} || [];
    return unless ref $history eq 'ARRAY';

    for my $msg (@$history) {
        next unless ref $msg eq 'HASH';
        my $role = $msg->{role} || '';
        next unless $role eq 'user';

        my $content = $msg->{content} || '';
        if (ref $content eq 'ARRAY') {
            my @parts;
            for my $p (@$content) {
                if (ref $p eq 'HASH') {
                    push @parts, ($p->{text} || '');
                } elsif (!ref $p) {
                    push @parts, $p;
                }
            }
            $content = join(' ', @parts);
        }
        next unless defined $content && !ref $content;

        # Skip system injections
        next if $content =~ /^\[TOOL_RESULT/;
        next if $content =~ /^<system/;
        next if $content =~ /USER INTERRUPT/;
        next if length($content) < 5;

        $results->{total_user_msgs}++;
        $results->{projects}{$project}{user_msgs}++;

        # Communication style analysis
        my $stripped = $content;
        $stripped =~ s/^\s+|\s+$//g;

        my $style = $results->{style};

        # Message length distribution
        if (length($stripped) < 50) {
            $style->{short_messages}++;
        } elsif (length($stripped) < 200) {
            $style->{medium_messages}++;
        } else {
            $style->{long_detailed_messages}++;
        }

        # Concise approvals
        if ($stripped =~ /^(yes|no|ok|okay|sure|go ahead|do it|proceed|looks good|lgtm|ship it|commit|push|yep|nope|perfect|great|thanks|approved|done|next)\s*[.!]?$/i) {
            $style->{concise_approvals}++;
        }

        # Collaborative language
        $style->{collaborative_language}++ if $stripped =~ /\b(we|us|our|let's|together)\b/i;

        # States desires
        $style->{states_desires}++ if $stripped =~ /\b(I want|I need|I'd like|I would like|I prefer|please)\b/i;

        # Corrections and redirects
        $style->{corrections_redirects}++ if $stripped =~ /\b(wrong|no |nope|incorrect|bad|not what|that's not|don't|stop|undo|revert|actually)\b/i;

        # Positive feedback
        $style->{positive_feedback}++ if $stripped =~ /\b(good|great|perfect|nice|thanks|thank you|awesome|excellent|love it|well done|looks good|amazing|beautiful)\b/i;

        # Bug reports with context
        $style->{bug_reports}++ if $stripped =~ /\b(bug|error|crash|broken|fails?|issue|problem|not working|doesn.t work|exception|stack trace|traceback)\b/i;

        # Includes code or error output
        $style->{includes_code}++ if $stripped =~ /```|`[^`]+`/;

        # Shares URLs
        $style->{shares_urls}++ if $stripped =~ /https?:\/\//;

        # Strategic/architectural thinking
        $style->{strategic_thinking}++ if $stripped =~ /\b(architecture|design|pattern|approach|strategy|philosophy|vision|goal|roadmap|plan|tradeoff)\b/i;

        # Provides context/reasoning
        $style->{provides_context}++ if $stripped =~ /\b(because|since|the reason|context|background|note that|keep in mind|for context)\b/i;

        # Adds requirements iteratively
        $style->{adds_requirements_iteratively}++ if $stripped =~ /\b(also|and also|another thing|one more|additionally|while you.re at it|oh and)\b/i;

        # References past work
        $style->{references_past_work}++ if $stripped =~ /\b(before|previously|last time|earlier|we did|remember|like we|as we discussed)\b/i;

        # Questions
        $style->{asks_questions}++ if $stripped =~ /\?/;

        # Humor and personality (lol, haha, emoticons, :D, etc.)
        $style->{uses_humor}++ if $stripped =~ /\b(lol|lmao|haha|heh|rofl)\b|[:;][)D(P]|:\)|:\(|:D|;\)|xD/i;

        # Tactical directives (specific, hands-on instructions)
        $style->{tactical_directives}++ if $stripped =~ /\b(run this|change this|fix this|add .+ to|remove .+ from|replace .+ with|move .+ to|rename|delete this|update this)\b/i;

        # Delegates high-level (trusts agent to figure out details)
        $style->{delegates_high_level}++ if $stripped =~ /\b(implement|create|build|set up|handle|take care of|figure out|make it work|get .+ working)\b/i;

        # Micromanages details (provides very specific implementation instructions)
        $style->{micromanages_details}++ if $stripped =~ /\b(on line \d|in function|in method|in file|use exactly|change .+ to .+|set .+ to .+|at line)\b/i;

        # Urgency signals
        $style->{urgency_signals}++ if $stripped =~ /\b(quickly|asap|urgent|important|priority|right away|immediately|hurry|rush|critical)\b/i;

        # Patience signals
        $style->{patience_signals}++ if $stripped =~ /\b(take your time|no rush|no hurry|when you get to it|whenever|at your pace|no pressure)\b/i;

        # Quality focus (verification, testing, correctness)
        $style->{quality_focus}++ if $stripped =~ /\b(test it|verify|make sure|double.check|confirm|validate|check that|ensure|regression|coverage)\b/i;

        # Learning/exploring (seeking understanding)
        $style->{learning_exploring}++ if $stripped =~ /\b(explain|how does|teach me|why does|what is|help me understand|what.s the difference|can you show|walk me through)\b/i;

        # Grants autonomy (trusts agent's judgment)
        $style->{grants_autonomy}++ if $stripped =~ /\b(you decide|your call|up to you|whatever you think|use your judgment|your choice|however you want|I trust)\b/i;

        # Frustration signals (repeated corrections, emphasis)
        if ($stripped =~ /\b(I already said|I told you|again|still not|still wrong|not what I asked)\b/i
            || ($stripped =~ /[A-Z]{3}/ && $stripped =~ /[a-z]/)  # Mixed case with caps emphasis
            || $stripped =~ /!{2}/) {  # Multiple exclamation marks
            $style->{frustration_signals}++;
        }

        # Topic/technology keywords (broad coverage)
        my $topics = $results->{topics};
        my @tech_keywords = qw(
            perl python ruby javascript typescript java kotlin swift
            go rust c cpp csharp php bash shell zsh powershell
            html css json yaml toml xml sql graphql
            git docker kubernetes terraform ansible
            react vue angular svelte node npm yarn
            flask django rails spring express
            api rest grpc websocket
            linux macos windows android ios
            aws gcp azure cloudflare vercel
            postgres mysql sqlite redis mongodb
            test debug deploy build release install configure
            ci cd pipeline workflow
        );
        for my $kw (@tech_keywords) {
            if ($kw eq 'c') {
                # Avoid matching 'c' as a standalone word too broadly
                $topics->{$kw}++ if $stripped =~ /\bC\b(?!\+\+|#)/;
            } elsif ($kw eq 'cpp') {
                $topics->{'c++'}++ if $stripped =~ /\bc\+\+\b/i;
            } elsif ($kw eq 'csharp') {
                $topics->{'c#'}++ if $stripped =~ /\bc#\b/i;
            } else {
                $topics->{$kw}++ if $stripped =~ /\b\Q$kw\E\b/i;
            }
        }
        # Additional multi-word or case-sensitive topics
        $topics->{API}++ if $stripped =~ /\bAPI\b/;
        $topics->{UI}++ if $stripped =~ /\bUI\b/;
        $topics->{'machine learning'}++ if $stripped =~ /\b(machine learning|ML|deep learning|neural net)\b/i;

        # Store sample messages (cap at 200)
        if (@{$results->{user_messages}} < 200) {
            push @{$results->{user_messages}}, {
                project => $project,
                content => substr($content, 0, 500),
            };
        }
    }
}

1;

__END__

=head1 PROFILE ANALYSIS FLOW

The profile building flow works in two stages:

=over 4

=item 1. Statistical Analysis (this module)

Scans session history to extract quantitative data (style counters, topic
frequencies) and qualitative data (sample messages). This data is objective
and user-independent.

=item 2. AI-Assisted Synthesis (via /profile build)

The analysis data and sample messages are sent to the AI, which collaborates
with the user to synthesize a personalized profile. The AI can identify
patterns, ask clarifying questions, and adapt to any user's workflow.

=back

This separation ensures the Analyzer doesn't embed assumptions about any
specific user's preferences. The AI handles synthesis; the Analyzer handles
data collection.

=cut
