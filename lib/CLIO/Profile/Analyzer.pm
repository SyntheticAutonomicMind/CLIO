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
to generate a draft profile that the user can review and refine.

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
                 Defaults to current directory and home .clio/

Returns:
- Hashref with analysis results

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

    # Derive profile traits from raw data
    $results{profile_traits} = $self->_derive_traits(\%results);

    return \%results;
}

=head2 generate_profile_draft

Generate a markdown profile from analysis results.

Arguments:
- $analysis: Hashref from analyze_sessions()

Returns:
- String containing draft profile markdown

=cut

sub generate_profile_draft {
    my ($self, $analysis) = @_;

    my $traits = $analysis->{profile_traits} || {};
    my $style = $analysis->{style} || {};
    my $total = $analysis->{total_user_msgs} || 1;

    my @sections;

    # Communication style
    my @comm;
    if (($style->{collaborative_language} || 0) / $total > 0.3) {
        push @comm, 'Uses collaborative language (we/us/our/let\'s)';
    }
    if (($style->{short_messages} || 0) / $total > 0.3) {
        push @comm, 'Prefers short, direct messages';
    } elsif (($style->{long_detailed_messages} || 0) / $total > 0.3) {
        push @comm, 'Provides detailed context in messages';
    }
    if (($style->{corrections_redirects} || 0) / $total > 0.1) {
        push @comm, 'Frequently course-corrects and gives direct feedback';
    }
    if (($style->{positive_feedback} || 0) / $total > 0.05) {
        push @comm, 'Gives positive feedback when work is good';
    }
    if (($style->{concise_approvals} || 0) / $total > 0.03) {
        push @comm, 'Uses concise approvals (proceed, yes, go ahead)';
    }
    if (($style->{states_desires} || 0) / $total > 0.1) {
        push @comm, 'States desires explicitly (I want, I need, I\'d like)';
    }

    push @sections, "**Communication:** " . join('. ', @comm) . '.' if @comm;

    # Working style
    my @work;
    if (($style->{bug_reports} || 0) / $total > 0.08) {
        push @work, 'Provides detailed bug reports with logs and context';
    }
    if (($style->{includes_code} || 0) / $total > 0.1) {
        push @work, 'Includes code snippets and error output in messages';
    }
    if (($style->{shares_urls} || 0) / $total > 0.05) {
        push @work, 'Shares URLs for reference and context';
    }
    if (($style->{strategic_thinking} || 0) / $total > 0.05) {
        push @work, 'Thinks strategically about architecture and design';
    }
    if (($style->{adds_requirements_iteratively} || 0) / $total > 0.05) {
        push @work, 'Adds requirements iteratively during work';
    }
    if (($style->{references_past_work} || 0) / $total > 0.05) {
        push @work, 'References past work and previous sessions';
    }

    push @sections, "**Working style:** " . join('. ', @work) . '.' if @work;

    # Detected preferences from message content
    my @prefs;
    if ($traits->{prefers_squash_commits}) {
        push @prefs, 'Squash commits before pushing';
    }
    if ($traits->{dont_push_without_asking}) {
        push @prefs, 'Don\'t push without asking';
    }
    if ($traits->{tests_on_real_hardware}) {
        push @prefs, 'Tests on real hardware before release';
    }
    if ($traits->{values_privacy}) {
        push @prefs, 'Privacy-first approach';
    }
    if ($traits->{minimal_dependencies}) {
        push @prefs, 'Minimal dependencies';
    }
    if ($traits->{clean_code_comments}) {
        push @prefs, 'Brief code comments (what, not why)';
    }

    push @sections, "**Preferences:** " . join('. ', @prefs) . '.' if @prefs;

    # Technology focus
    my @techs;
    my $topics = $analysis->{topics} || {};
    for my $tech (sort { ($topics->{$b} || 0) <=> ($topics->{$a} || 0) } keys %$topics) {
        last if @techs >= 8;
        next if ($topics->{$tech} || 0) < 3;
        push @techs, $tech;
    }

    push @sections, "**Technical focus:** " . join(', ', @techs) . '.' if @techs;

    # Active projects
    my @projects;
    my $proj_data = $analysis->{projects} || {};
    for my $p (sort { ($proj_data->{$b}{user_msgs} || 0) <=> ($proj_data->{$a}{user_msgs} || 0) } keys %$proj_data) {
        last if @projects >= 6;
        next if ($proj_data->{$p}{user_msgs} || 0) < 3;
        push @projects, "$p ($proj_data->{$p}{user_msgs} msgs)";
    }

    push @sections, "**Active projects:** " . join(', ', @projects) . '.' if @projects;

    my $draft = "## User Profile\n\n";
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
        # Add just the home dir for its .clio/sessions/ - no recursive scan
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

        # Message length
        if (length($stripped) < 50) {
            $style->{short_messages}++;
        } elsif (length($stripped) < 200) {
            $style->{medium_messages}++;
        } else {
            $style->{long_detailed_messages}++;
        }

        # Concise approvals
        if ($stripped =~ /^(yes|no|ok|okay|sure|go ahead|do it|proceed|looks good|lgtm|ship it|commit|push|yep|nope|perfect|great|thanks)\s*[.!]?$/i) {
            $style->{concise_approvals}++;
        }

        # Collaborative language
        $style->{collaborative_language}++ if $stripped =~ /\b(we|us|our|let's|together)\b/i;

        # States desires
        $style->{states_desires}++ if $stripped =~ /\b(I want|I need|I'd like|I would like)\b/i;

        # Corrections
        $style->{corrections_redirects}++ if $stripped =~ /\b(wrong|no |nope|incorrect|bad|not what|that's not|don't|stop|undo)\b/i;

        # Positive feedback
        $style->{positive_feedback}++ if $stripped =~ /\b(good|great|perfect|nice|thanks|thank you|awesome|excellent|love it|well done)\b/i;

        # Bug reports
        $style->{bug_reports}++ if $stripped =~ /\b(bug|error|crash|broken|fails?|issue|problem|not working|doesn.t work)\b/i;

        # Includes code
        $style->{includes_code}++ if $stripped =~ /```|`[^`]+`/;

        # Shares URLs
        $style->{shares_urls}++ if $stripped =~ /https?:\/\//;

        # Strategic thinking
        $style->{strategic_thinking}++ if $stripped =~ /\b(architecture|design|pattern|approach|strategy|philosophy|vision|goal|roadmap)\b/i;

        # Provides context
        $style->{provides_context}++ if $stripped =~ /\b(because|since|the reason|context|background|note that|keep in mind)\b/i;

        # Adds iteratively
        $style->{adds_requirements_iteratively}++ if $stripped =~ /\b(also|and also|another thing|one more|additionally|while you.re at it)\b/i;

        # References past work
        $style->{references_past_work}++ if $stripped =~ /\b(before|previously|last time|earlier|we did|remember|like we)\b/i;

        # Questions
        $style->{asks_questions}++ if $stripped =~ /\?/;

        # Topic/technology keywords
        my $topics = $results->{topics};
        for my $kw (qw(perl swift python bash shell javascript html css json yaml git commit branch merge push pull docker container test debug deploy build release install configure)) {
            $topics->{$kw}++ if $stripped =~ /\b$kw\b/i;
        }
        for my $kw (qw(API UI interface frontend backend database server)) {
            $topics->{$kw}++ if $stripped =~ /\b$kw\b/i;
        }

        # Store sample messages (cap at 200)
        if (@{$results->{user_messages}} < 200) {
            push @{$results->{user_messages}}, {
                project => $project,
                content => substr($content, 0, 500),
            };
        }
    }
}

sub _derive_traits {
    my ($self, $results) = @_;

    my %traits;
    my $msgs = $results->{user_messages} || [];

    for my $msg (@$msgs) {
        my $c = $msg->{content} || '';

        # Git workflow preferences
        $traits{prefers_squash_commits}++ if $c =~ /squash/i;
        $traits{dont_push_without_asking}++ if $c =~ /don't push|do not push|but don't push|commit but/i;
        $traits{tests_on_real_hardware}++ if $c =~ /deploy.*to|test.*on|ssh\s+\w+@/i;

        # Code quality preferences
        $traits{clean_code_comments}++ if $c =~ /comment|annotation|dramatic|slop/i;
        $traits{minimal_dependencies}++ if $c =~ /dependen|minimal|lightweight|no.*(node|npm|yarn)/i;
        $traits{values_privacy}++ if $c =~ /privacy|telemetry|local.first|no.account/i;
    }

    # Normalize: flag is true if pattern appeared in >1% of messages
    my $threshold = @$msgs * 0.01;
    $threshold = 1 if $threshold < 1;

    for my $k (keys %traits) {
        $traits{$k} = ($traits{$k} >= $threshold) ? 1 : 0;
    }

    return \%traits;
}

1;
