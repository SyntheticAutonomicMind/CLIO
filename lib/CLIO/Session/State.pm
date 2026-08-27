# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

if ($ENV{CLIO_DEBUG}) {
    log_debug('SessionState', "CLIO::Session::State loaded");
}
package CLIO::Session::State;

=head1 NAME

CLIO::Session::State - Session state persistence and serialization

=head1 DESCRIPTION

Manages the persistent state of a CLIO session, including conversation history,
memory modules (STM, LTM, YaRN), billing/usage tracking, and session metadata.
Handles atomic file saves, state migration from older formats, and session cleanup.

=head1 SYNOPSIS

    use CLIO::Session::State;
    
    # Create new state
    my $state = CLIO::Session::State->new(session_id => $id);
    $state->add_message('user', 'Hello');
    $state->save();
    
    # Load existing state
    my $state = CLIO::Session::State->load($session_id);

=cut

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::Core::Logger qw(log_error log_warning log_debug log_info);
use CLIO::Util::UUID qw(uuid_v4);
use CLIO::Util::PathResolver;
use File::Spec;
use CLIO::Util::JSON qw(encode_json decode_json safe_decode_json);
use Fcntl qw(:flock);
use CLIO::Util::AtomicWrite qw(atomic_write);
use Cwd qw(getcwd abs_path);
use POSIX qw(strftime);
# File::Basename::dirname is called inside sub save() to derive the session
# directory from the session file path. Load it explicitly so the call
# doesn't depend on File::Basename being pulled in transitively by some
# other module CLIO happens to load first.
use File::Basename qw(dirname);
use CLIO::Memory::ShortTerm;
use CLIO::Memory::LongTerm;
use CLIO::Memory::YaRN;
use CLIO::Memory::TokenEstimator;
use CLIO::Util::TextSanitizer qw(strip_conversation_tags);
use CLIO::Core::Defaults qw(DEFAULT_CONTEXT_WINDOW DEFAULT_MAX_OUTPUT_TOKENS);

sub new {
    my ($class, %args) = @_;
    if ($ENV{CLIO_DEBUG} || $args{debug}) {
        log_debug('State::new', "called with args: " . join(", ", map { "$_=$args{$_}" } keys %args));
    }
    my $self = {
        session_id => $args{session_id},
        history    => [],
        debug      => $args{debug} // 0,
        file       => _session_file($args{session_id}),
        stm        => $args{stm} // CLIO::Memory::ShortTerm->new(debug => $args{debug}),
        ltm        => $args{ltm} // CLIO::Memory::LongTerm->new(debug => $args{debug}),
        yarn       => $args{yarn} // CLIO::Memory::YaRN->new(debug => $args{debug}),
        # Working directory
        working_directory => $args{working_directory} || getcwd(),
        # Loaded skills (merged into system prompt)
        loaded_skills => [],
        # GitHub Copilot session continuation
        _stateful_markers => [],
        # Session creation timestamp (for proper resume ordering)
        created_at => $args{created_at} // time(),
        # Human-friendly session name (auto-generated or user-set)
        session_name => $args{session_name} // undef,
        # Billing tracking fields
        billing    => {
            total_prompt_tokens => 0,
            total_completion_tokens => 0,
            total_tokens => 0,
            total_requests => 0,
            total_premium_requests => 0,  # GitHub Copilot AI Credits charged
            model => undef,  # Current model being used
            multiplier => 0,  # Billing multiplier from GitHub Copilot (legacy, all 1x as of June 2026)
            requests => [],  # Array of individual request billing records
        },
        # Context files
        context_files => [],
        # Context management configuration
        max_tokens => $args{max_tokens} // 128000,           # Model context window (updated at runtime)
        # Cached API payload (the exact @messages array last sent to the provider)
        # On session resume this is loaded verbatim - no rebuild from history needed.
        last_api_payload => [],       # Arrayref of message hashes
        last_api_metadata => {        # Snapshot at save time, drives reuse decisions
            model          => undef,  # Model ID at save time
            provider       => undef,  # Provider name at save time
            context_window => 0,      # Model context window at save time
            tools_signature => undef, # Digest of tools array (MCP/plugin drift detection)
            saved_at       => 0,      # Unix timestamp of save
        },
        # Session goals: persistent task-tracking goals managed by the model.
        # Stored as an arrayref of {id, title, description, status, created_at}.
        # Always injected into user_context by PromptBuilder (no loading step
        # required) so the agent has its goals in view every turn. Survives
        # context trims because the storage is the session file, not memory.
        session_goals => [],  # Arrayref of goal hashes
    };
    bless $self, $class;
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        log_debug('SessionState', "[STATE] yarn object ref: $self->{yarn}");
        log_debug('State::new', "returning self: $self");
    }
    return $self;
}

sub _session_file {
    my ($session_id) = @_;
    return CLIO::Util::PathResolver::get_session_file($session_id);
}

sub save {
    my ($self) = @_;
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        print "[STATE][FORCE] Entered save method for $self->{file}\n";
    }
    
    # Save project-level LTM to .clio/ltm.json (shared across all sessions)
    # Resolve via PathResolver::find_ltm_path so the write target converges with
    # the read target used at session load time. Walking up the project tree
    # ensures we don't create shadow LTM files at intermediate paths.
    if ($self->{ltm}) {
        require CLIO::Util::PathResolver;
        my $current_dir = getcwd();
        my $ltm_file = CLIO::Util::PathResolver::find_ltm_path($current_dir);
        eval { $self->{ltm}->save($ltm_file); };
        if ($@) {
            log_warning('State', "Failed to save LTM: $@");
        }
    }
    
my $data = {
        history => $self->{history},
        stm     => $self->{stm}->{history},
        # LTM is now saved separately to .clio/ltm.json (project-level, not session-level)
        yarn    => $self->{yarn}->{threads},
        working_directory => $self->{working_directory},
        created_at => $self->{created_at},  # Preserve session creation timestamp
        lastGitHubCopilotResponseId => $self->{lastGitHubCopilotResponseId},
        _stateful_markers => $self->{_stateful_markers} || [],  # GitHub Copilot session continuation
        billing => $self->{billing},  # Save billing data
        quota => $self->{quota},  # Save quota snapshot (from GitHub Copilot headers)
        max_tokens => $self->{max_tokens},  # Model context window for trim threshold
        context_files => $self->{context_files} || [],  # Save context files
        selected_model => $self->{selected_model},  # Save currently selected model
        api_config => $self->{api_config} || {},  # Save API config (from /api set --session)
        style => $self->{style},  # Save current color style
        theme => $self->{theme},  # Save current output theme
        session_name => $self->{session_name},  # Human-friendly session name
        loaded_skills => $self->{loaded_skills} || [],  # Skills merged into system prompt
        input_history => $self->{input_history} || [],  # User input readline history
        last_api_payload => $self->{last_api_payload} || [],  # Exact @messages last sent to the API
        last_api_metadata => $self->{last_api_metadata} || {   # Snapshot for reuse decisions
            model          => undef,
            provider       => undef,
            context_window => 0,
            tools_signature => undef,
            saved_at       => 0,
        },
        session_goals => $self->{session_goals} || [],  # Persistent task goals (injected into user_context)
    };
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        require Data::Dumper;
        log_debug('SessionState', "[STATE][DEBUG] Data to save: " . Data::Dumper::Dumper($data) . "");
    }
    
    # Acquire exclusive lock to prevent concurrent writes from multiple processes
    # sharing the same session file. The lock is on the target file path itself.
    my $lock_fh;
    open($lock_fh, '>>', $self->{file}) or do {
        log_warning('State', "Cannot open session file for locking: $!");
    };
    if ($lock_fh) {
        flock($lock_fh, LOCK_EX) or log_warning('State', "Cannot acquire exclusive lock: $!");
    }

    # Ensure session directory exists before writing with secure permissions
    my $dir = File::Basename::dirname($self->{file});
    unless (-d $dir) {
        require File::Path;
        eval { File::Path::make_path($dir, { mode => 0700 }) };
        if ($@) {
            log_warning('State', "Failed to create session directory: $@");
        }
    }
    
    # Atomic write with secure permissions (encode_json produces UTF-8 bytes)
    atomic_write($self->{file}, encode_json($data), mode => 0600);

    # Release lock (close releases flock)
    close($lock_fh) if $lock_fh;
}
sub load {
    my ($class, $session_id, %args) = @_;
    my $file = _session_file($session_id);
    log_debug('State::load', "called for session_id: $session_id, file: $file");
    return unless -e $file;
    # Use raw bytes mode - decode_json() expects UTF-8 bytes
    open my $fh, '<:raw', $file or return;
    # Acquire shared lock for reading (prevents reading during a concurrent write)
    flock($fh, LOCK_SH);
    local $/; my $json = <$fh>; close $fh;
    my $data = safe_decode_json($json);
    log_debug('SessionState', "State::load loaded data: " . (defined $data ? 'ok' : 'undef'));
    return unless $data;
    
    # Determine working directory for loading project LTM
    # Use getcwd() for cross-platform compatibility
    # The stored working_directory may be from a different machine (e.g., /Users/... on Linux)
    my $working_dir = getcwd();

    # Load project-level LTM from .clio/ltm.json (shared across all sessions).
    # Use PathResolver::find_ltm_path so the load target converges with the write
    # target used by MemoryOperations - prevents shadow LTM files when sessions
    # are loaded from a subdirectory of a repo.
    require CLIO::Util::PathResolver;
    my $ltm_file = CLIO::Util::PathResolver::find_ltm_path($working_dir);
    my $ltm = CLIO::Memory::LongTerm->load($ltm_file, debug => $args{debug});
    
    # Fallback: If old session has ltm->{store} data, migrate it
    if (!-e $ltm_file && $data->{ltm} && ref($data->{ltm}) eq 'HASH') {
        log_info('State', "Migrating legacy LTM data to new format");
        $ltm = CLIO::Memory::LongTerm->new(debug => $args{debug});
        # Convert old store format to discoveries
        for my $key (keys %{$data->{ltm}}) {
            $ltm->add_discovery("$key: $data->{ltm}{$key}", 0.5, 0);
        }
        # Save migrated data
        eval { $ltm->save($ltm_file); };
    }
    
    # Load STM - with migration for corrupted data from old sessions
    my $stm_data = $data->{stm} // [];
    
    # MIGRATION: Clean up corrupted STM entries where role is a hash instead of string
    # Old bug caused: {role => {role => "user", content => "text"}, content => undef}
    # Should be: {role => "user", content => "text"}
    my @cleaned_stm;
    for my $entry (@$stm_data) {
        next unless ref($entry) eq 'HASH';
        
        my $role = $entry->{role};
        my $content = $entry->{content};
        
        # Fix nested role structure
        if (ref($role) eq 'HASH') {
            $content = $role->{content} if defined $role->{content};
            $role = $role->{role} if defined $role->{role};
        }
        
        # Only add if we have valid data
        if (defined $role && !ref($role)) {
            push @cleaned_stm, {
                role => $role,
                content => $content // ''
            };
        }
    }
    
    my $stm  = CLIO::Memory::ShortTerm->new(history => \@cleaned_stm, debug => $args{debug});

    # MIGRATION: Clean up corrupted history entries where content is a hash/array ref.
    # Old ReadLine bug could leak control signals like {type=>'__TIMEOUT__'} into user
    # input. They were saved as user message content (hash ref) instead of a string.
    # Strict-schema providers (e.g. NVIDIA NIM) reject these with
    # "data did not match any variant of untagged enum
    # ChatCompletionRequestUserMessageContent". Permissive providers (minimax) accept
    # them, which is why the bug was invisible in some sessions and fatal in others.
    # Coerce ref content to a string marker preserving the message so the surrounding
    # conversation flow (assistant+tool sequences) stays intact.
    my $history_data = $data->{history} || [];
    my @cleaned_history;
    my $corruption_migrated = 0;
    for my $i (0 .. $#$history_data) {
        my $entry = $history_data->[$i];
        unless (ref($entry) eq 'HASH') {
            push @cleaned_history, $entry;
            next;
        }

        # Mirror the STM role fixup so {role=>{role=>..., content=>...}}->{content=>undef}
        # also gets cleaned.
        my $role = $entry->{role};
        my $content = $entry->{content};
        if (ref($role) eq 'HASH') {
            $content = $role->{content} if defined $role->{content};
            $role = $role->{role} if defined $role->{role};
            $entry->{role} = $role;
            $entry->{content} = $content;
        }

        # Coerce ref content to a string marker. Keep the message so tool_call /
        # tool_result pairing and assistant turn order remain valid.
        if (ref($content) ne '') {
            my $ref_type = ref($content);
            my $inner = '';
            if ($ref_type eq 'HASH' && defined $content->{type}) {
                $inner = " type='$content->{type}'";
            }
            $content = "[CORRUPTED INPUT: " . $ref_type . $inner
                . ' - migrated by session loader]';
            $corruption_migrated++;
        }
        $entry->{content} = $content if defined $content;
        push @cleaned_history, $entry;
    }
    $data->{history} = \@cleaned_history;
    if ($corruption_migrated) {
        $data->{_corruption_migrated} = $corruption_migrated;
        log_info('State::load', "Migrated $corruption_migrated corrupted message(s) "
            . "(hash/array content -> string marker). Session will be re-saved to persist fix.");
    }
    my $yarn = CLIO::Memory::YaRN->new(threads => $data->{yarn} // {}, debug => $args{debug});
    my $self = {
        session_id => $session_id,
        history    => $data->{history} || [],
        debug      => $args{debug} // 0,
        file       => $file,
        stm        => $stm,
        ltm        => $ltm,
        yarn       => $yarn,
        working_directory => $working_dir,
        lastGitHubCopilotResponseId => $data->{lastGitHubCopilotResponseId},
        # Load session creation timestamp (for proper resume ordering)
        created_at => $data->{created_at} // time(),
        # Load billing data or initialize if not present
        billing    => $data->{billing} || {
            total_prompt_tokens => 0,
            total_completion_tokens => 0,
            total_tokens => 0,
            total_requests => 0,
            total_premium_requests => 0,  # GitHub Copilot AI Credits charged
            model => undef,
            multiplier => 0,
            requests => [],
        },
        # Load context files or initialize if not present
        context_files => $data->{context_files} || [],
        # Load quota snapshot (from GitHub Copilot headers)
        quota => $data->{quota},
        # Load selected model or default to undef
        selected_model => $data->{selected_model},
        # Load API config (from /api set --session)
        api_config => $data->{api_config} || {},
        # Load theme settings
        style => $data->{style} || 'default',
        theme => $data->{theme} || 'default',
        # Load stateful markers for GitHub Copilot session continuation
        _stateful_markers => $data->{_stateful_markers} || [],
        # Context management configuration
        max_tokens => $args{max_tokens} // $data->{max_tokens} // 128000,
        # Human-friendly session name
        session_name => $data->{session_name} // undef,
        # Loaded skills (merged into system prompt)
        loaded_skills => $data->{loaded_skills} || [],
        # User input readline history (persisted across sessions)
        input_history => $data->{input_history} || [],
        # Cached API payload (last @messages sent to the provider) - drives the
        # "reload current state" fast path on resume. Both fields are absent in
        # sessions created before this feature shipped; the rebuild path runs
        # until the next API call writes them.
        last_api_payload => $data->{last_api_payload} || [],
        last_api_metadata => $data->{last_api_metadata} || {
            model          => undef,
            provider       => undef,
            context_window => 0,
            tools_signature => undef,
            saved_at       => 0,
        },
        # Session goals: persistent task goals managed by the model. Always
        # present in user_context every turn (no loading step). Survives
        # context trims because storage is the session file.
        session_goals => $data->{session_goals} || [],
    };
    bless $self, $class;
    
    # Validate and repair conversation history
    # Detect orphaned tool_calls (incomplete tool execution due to interruption)
    my $repaired = $self->_validate_and_repair_history();
    if ($repaired) {
        # Store repair message to be displayed to user as styled system message
        # (instead of raw debug warnings)
        $self->{repair_notification} = $repaired;
    }
    
    # Persist corruption migration immediately so subsequent loads don't re-migrate.
    if ($data->{_corruption_migrated}) {
        eval { $self->save(); };
        if ($@) {
            log_warning('State::load', "Failed to persist corruption migration: $@");
        }
    }
    log_debug('State::load', "returning self: $self");
    
    # Restore model to ENV if one was saved (so it persists across resume)
    if ($self->{selected_model}) {
        $ENV{OPENAI_MODEL} = $self->{selected_model};
        log_info('State::load', "Restored model from session: $self->{selected_model}");
    }
    
    return $self;
}

# Accessors for memory modules
sub stm  { $_[0]->{stm} }
sub ltm  { $_[0]->{ltm} }
sub yarn { $_[0]->{yarn} }

# Get repair notification if session history was repaired on load
sub repair_notification { $_[0]->{repair_notification} }
sub session_name {
    my ($self, $name) = @_;
    if (defined $name) {
        $self->{session_name} = $name;
    }
    return $self->{session_name};
}

=head2 auto_name_session

Generate a session name from the first user message in history if no name
is set yet. Called programmatically after the first user message is saved
to session state — CLIO owns session naming instead of asking the model
to emit an HTML comment marker.

Returns: 1 if a name was assigned, 0 otherwise.

=cut

sub auto_name_session {
    my ($self) = @_;

    # Don't overwrite an existing name (from AI marker or explicit set)
    return 0 if $self->{session_name};

    my $history = $self->{history};
    return 0 unless $history && ref($history) eq 'ARRAY';

    # Find the first user message
    my $first_user_msg;
    for my $msg (@$history) {
        next unless ref($msg) eq 'HASH';
        next unless ($msg->{role} || '') eq 'user';
        $first_user_msg = $msg->{content} || '';
        last;
    }

    return 0 unless $first_user_msg && length($first_user_msg) > 0;

    my $name = _generate_session_name($first_user_msg);
    if ($name && length($name) > 0) {
        $self->{session_name} = $name;
        log_debug('State', "Auto-generated session name: $name");
        return 1;
    }

    return 0;
}

=head2 _generate_session_name

Generate a concise session name from user input text.
Returns a string of up to 60 characters, truncated at word boundary.

=cut

sub _generate_session_name {
    my ($text) = @_;

    return unless defined $text && length($text) > 0;

    my $name = $text;

    # Remove leading/trailing whitespace
    $name =~ s/^\s+//;
    $name =~ s/\s+$//;

    # Collapse multiple whitespace to single space
    $name =~ s/\s+/ /g;

    # Remove common filler phrases at the start
    $name =~ s/^(?:hey|hi|hello|please|can you|could you|i want to|i need to|i'd like to|let's)\s+//i;

    # Capitalize first letter
    $name = ucfirst($name);

    # Truncate to 60 chars at word boundary
    if (length($name) > 60) {
        $name = substr($name, 0, 60);
        $name =~ s/\s+\S*$//;
        $name .= '...' if length($name) > 0;
    }

    return undef if length($name) < 3;
    return $name;
}

=head2 session_goals / get_session_goals / set_session_goals

Persistent task-tracking goals managed by the model. Goals live in the
session file (not a separate memory file) so they:

- Survive context trims (storage is the session, not memory)
- Are race-free across concurrent sessions (each session has its own file)
- Are always in PromptBuilder::user_context view (no loading step)
- Persist across --resume (loaded with the session)

Format: Arrayref of hashrefs {id, title, description, status, created_at}
Status values: active, completed, blocked.

=cut

sub session_goals {
    my ($self) = @_;
    return $self->{session_goals} || [];
}

sub get_session_goals {
    my ($self) = @_;
    return $self->{session_goals} || [];
}

sub set_session_goals {
    my ($self, $goals) = @_;
    $self->{session_goals} = $goals || [];
    return $self->{session_goals};
}

=head2 last_api_payload / last_api_metadata / section_signatures

Cache the conversation state at end of turn so a resumed session can pick
up with byte-identical context instead of rebuilding from scratch.

The snapshot is captured by WorkflowOrchestrator::process_input AFTER tool
execution completes (so it includes the assistant response, tool_calls, and
tool_results persisted during the turn). The resume fast path consumes this
in CLIO::Core::WorkflowOrchestrator::_try_resume_from_payload.

Contract: snapshot must equal what load_conversation_history would return
after rebuilding from session history. Otherwise the resume fast path and
the rebuild path produce different prompts, breaking llama.cpp LCP cache
stability (CachyLLama bug reported 2026-08-18).

`section_signatures` is a hashref of SHA256 digests, one per pipeline
protocol section. Lets future consumers detect per-section drift and
selectively rebuild only the drifted sections (rather than discarding
the entire snapshot). Sections: system_prompt, summary, context_files,
dialog, tool_results, user_context, user_input. Sections that don't
end (in the current snapshot) have no entry.

=cut

sub last_api_payload  { $_[0]->{last_api_payload} }
sub last_api_metadata { $_[0]->{last_api_metadata} }
sub section_signatures { $_[0]->{last_api_metadata}{section_signatures} }

sub set_last_api_payload {
    my ($self, $payload, %opts) = @_;
    croak "payload must be an arrayref" unless ref($payload) eq 'ARRAY';

    # Deep-clone so later in-process mutation of the caller's @messages
    # array cannot corrupt the cached copy. Shallow copy of the top-level
    # array isn't enough because message hashes contain nested arrayrefs
    # (tool_calls) and hashrefs (tool_calls[i].function.arguments) that
    # are mutable in practice - the WorkflowOrchestrator mutates
    # assistant message tool_calls between API iterations.
    my $copy = _deep_clone_messages($payload);

    $self->{last_api_payload} = $copy;
    $self->{last_api_metadata} = {
        model          => $opts{model}          // $self->{last_api_metadata}{model}          // undef,
        provider       => $opts{provider}       // $self->{last_api_metadata}{provider}       // undef,
        context_window => $opts{context_window} // $self->{last_api_metadata}{context_window} // 0,
        tools_signature => $opts{tools_signature} // $self->{last_api_metadata}{tools_signature} // undef,
        section_signatures => $opts{section_signatures} // $self->{last_api_metadata}{section_signatures} // {},
        # Estimated token count for this payload using the local
        # estimate_tokens heuristic. Used by _try_resume_from_payload
        # to detect when the local estimate has drifted from reality
        # (e.g. a tokenizer mismatch causes the estimate to
        # undercount actual server-reported prompt_tokens). When
        # drift > 20% (estimated < actual by 1.2x or more) we tighten
        # the trim threshold so subsequent resumes fit on the first try
        # instead of round-tripping a 400.
        estimated_tokens       => $opts{estimated_tokens}       // $self->{last_api_metadata}{estimated_tokens}       // 0,
        # Real prompt token count from a successful API response, when
        # available. Saves a server round-trip when calculating the
        # estimate/actual drift ratio on resume.
        actual_tokens          => $opts{actual_tokens}          // $self->{last_api_metadata}{actual_tokens}          // 0,
        # Computed drift ratio (actual_tokens / estimated_tokens).
        # 1.0 = perfect match. >1.2 = underestimate, tighten threshold.
        # Cap at 4.0 to prevent runaway values from outliers (each model's
        # tokenizer behaves differently; a single bad sample shouldn't
        # poison subsequent turns).
        estimate_drift_ratio   => $opts{estimate_drift_ratio}   // $self->{last_api_metadata}{estimate_drift_ratio}   // 1.0,
        saved_at       => time(),
    };

    return $copy;
}

sub _deep_clone_messages {
    my ($messages) = @_;
    my $copy = [];
    for my $msg (@$messages) {
        if (ref($msg) eq 'HASH') {
            my %m = %$msg;
            # Recurse into known nested structures that may be mutated.
            $m{tool_calls} = _deep_clone_messages_list($m{tool_calls}) if ref($m{tool_calls}) eq 'ARRAY';
            $m{content}    = _deep_clone_content($m{content}) if ref($m{content});
            push @$copy, \%m;
        } else {
            push @$copy, $msg;
        }
    }
    return $copy;
}

sub _deep_clone_messages_list {
    my ($items) = @_;
    return [] unless ref($items) eq 'ARRAY';
    my $copy = [];
    for my $item (@$items) {
        if (ref($item) eq 'HASH') {
            my %h = %$item;
            # tool_calls entries have function.arguments (hashref) - clone it.
            if (ref($h{function}) eq 'HASH') {
                my %fn = %{$h{function}};
                $fn{arguments} = _deep_clone_json_value($fn{arguments}) if ref($fn{arguments});
                $h{function} = \%fn;
            }
            push @$copy, \%h;
        } else {
            push @$copy, $item;
        }
    }
    return $copy;
}

# Clone a tool message content value: in OpenAI format this is a string,
# but in Anthropic it can be an arrayref of typed blocks (text, tool_use,
# image). We preserve the structure but copy any nested hashes/arrays.
sub _deep_clone_content {
    my ($content) = @_;
    return _deep_clone_json_value($content);
}

sub _deep_clone_json_value {
    my ($v) = @_;
    return $v unless ref($v);
    if (ref($v) eq 'HASH') {
        my %h = %$v;
        for my $k (keys %h) { $h{$k} = _deep_clone_json_value($h{$k}); }
        return \%h;
    }
    if (ref($v) eq 'ARRAY') {
        return [ map { _deep_clone_json_value($_) } @$v ];
    }
    # Blessed or otherwise - leave alone, callers shouldn't mutate these.
    return $v;
}

sub clear_last_api_payload {
    my ($self) = @_;
    $self->{last_api_payload} = [];
    $self->{last_api_metadata} = {
        model          => undef,
        provider       => undef,
        context_window => 0,
        tools_signature => undef,
        saved_at       => 0,
    };
    return 1;
}

=head2 _validate_and_repair_history

Validate conversation history and repair orphaned tool_calls.

When a session is interrupted (e.g., Ctrl-C) during tool execution, the history
may contain assistant messages with tool_calls that don't have matching tool
result messages. This causes API errors on resume.

This method:
1. Scans for all tool_call_ids from assistant messages with tool_calls
2. Collects all tool_call_ids from tool result messages
3. Identifies orphaned tool_calls (those without matching results)
4. Removes the incomplete conversation exchange (user + assistant with orphans)

Returns: 1 if repairs were made, 0 if history was clean

=cut

sub _validate_and_repair_history {
    my ($self) = @_;
    
    return 0 unless $self->{history} && @{$self->{history}};
    
    my @history = @{$self->{history}};
    my %tool_result_ids;  # Track all tool_call_ids that have results
    my %tool_call_ids;    # Track all tool_call_ids from assistant messages
    my %orphan_indices;   # Track message indices that need to be removed
    
    # Pass 1: Collect all tool_call_ids from assistant messages with tool_calls
    for (my $i = 0; $i < @history; $i++) {
        my $msg = $history[$i];
        if ($msg->{role} && $msg->{role} eq 'assistant' && 
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                $tool_call_ids{$tc->{id}} = $i if $tc->{id};
            }
        }
    }
    
    # Pass 2: Collect all tool_call_ids that have matching tool results
    for (my $i = 0; $i < @history; $i++) {
        my $msg = $history[$i];
        if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
            $tool_result_ids{$msg->{tool_call_id}} = $i;
        }
    }
    
    # Pass 3: Find assistant messages with tool_calls that lack complete results
    for (my $i = 0; $i < @history; $i++) {
        my $msg = $history[$i];
        
        # Check assistant messages with tool_calls
        if ($msg->{role} && $msg->{role} eq 'assistant' && 
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            
            # Check if ALL tool_calls have matching results
            my @missing_ids;
            for my $tc (@{$msg->{tool_calls}}) {
                my $tc_id = $tc->{id};
                next unless $tc_id;
                
                unless ($tool_result_ids{$tc_id}) {
                    push @missing_ids, $tc_id;
                }
            }
            
            # If any tool_calls are missing results, mark this message for removal
            if (@missing_ids) {
                $orphan_indices{$i} = 1;
                
                # Log to debug only (not to user - suppressing raw [WARNING] messages)
                log_debug('SessionState', "Found orphaned tool_calls at index $i: " . join(', ', @missing_ids));
                
                # Also mark the preceding user message (if any) since they form a unit
                if ($i > 0 && $history[$i-1]{role} && $history[$i-1]{role} eq 'user') {
                    $orphan_indices{$i-1} = 1;
                    log_debug('SessionState', "Removing associated user message at index " . ($i-1));
                }
                
                # Also remove any partial tool results for THIS assistant's tool_calls
                # (in case some completed but not all)
                for my $tc (@{$msg->{tool_calls}}) {
                    my $tc_id = $tc->{id};
                    next unless $tc_id;
                    
                    # Find and mark any tool results for this tool_call_id
                    for (my $j = $i + 1; $j < @history; $j++) {
                        if ($history[$j]{role} && $history[$j]{role} eq 'tool' &&
                            $history[$j]{tool_call_id} && 
                            $history[$j]{tool_call_id} eq $tc_id) {
                            $orphan_indices{$j} = 1;
                        }
                    }
                }
            }
        }
    }
    
    # Pass 4: Find orphaned tool_results (tool_results without matching tool_calls)
    # This catches the reverse case: "unexpected tool_use_id found in tool_result blocks"
    for (my $i = 0; $i < @history; $i++) {
        my $msg = $history[$i];
        if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
            unless (exists $tool_call_ids{$msg->{tool_call_id}}) {
                $orphan_indices{$i} = 1;
                log_debug('SessionState', "Found orphaned tool_result at index $i: " . $msg->{tool_call_id} . " (no matching tool_call)");
            }
        }
    }
    
    # If no orphans found, history is clean
    return 0 unless keys %orphan_indices;
    
    # Pass 5: Rebuild history without orphaned messages
    my @cleaned_history;
    for (my $i = 0; $i < @history; $i++) {
        unless ($orphan_indices{$i}) {
            push @cleaned_history, $history[$i];
        }
    }
    
    my $removed_count = scalar(@history) - scalar(@cleaned_history);
    $self->{history} = \@cleaned_history;
    
    # Log to debug only (not to user - suppressing raw [WARNING] messages)
    log_debug('State', "Removed $removed_count messages with incomplete tool execution");
    
    # Save the repaired session immediately to persist the fix
    eval { $self->save(); };
    if ($@) {
        log_error('State', "Failed to save repaired session: $@");
    }
    
    # Return user-friendly message instead of just 1 (now this message will be displayed)
    return "Session restored. Ready to continue." if $removed_count >= 1;
    
    return 0;  # No repairs were made
}

sub add_message {
    my ($self, $role, $content, $opts) = @_;
    # Defense in depth: content must be a string for safe JSON serialization.
    # A non-string (hash/array ref) would silently corrupt the session file and
    # pollute the model's context on resume. Catch it here, log loudly, and
    # coerce to a string so the session remains recoverable. The real fix is
    # upstream (caller should not pass refs), but this is the last line of defense.
    if (ref $content) {
        log_error('State::add_message', sprintf(
            "BUG: add_message received non-string content (role=%s, type=%s) - "
            . "coercing to string to preserve session integrity. This indicates a "
            . "ReadLine control signal or similar ref leaked into user input.",
            $role // '<undef>',
            ref $content
        ));
        if (ref $content eq 'HASH' && defined $content->{type}) {
            $content = "[CORRUPTED INPUT: ref of type " . ref($content) . " with type='$content->{type}' - "
                . "this is a bug, please report]";
        } else {
            $content = "[CORRUPTED INPUT: ref of type " . ref($content) . "]";
        }
    }
    $content = strip_conversation_tags($content);
    
    # Generate unique turn ID (SAM compatibility)
    my $turn_id = uuid_v4();
    
    # Build message with SAM-compatible metadata
    my $message = { 
        role => $role, 
        content => $content,
        id => $turn_id,  # Turn ID for referencing specific messages
        timestamp => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime()),  # ISO 8601 format (SAM compatible)
        metadata => {
            sessionId => $self->{session_id},  # SAM compatibility
            source => $opts->{source} || 'primary',  # Track message origin (primary, subagent, etc.)
            collaboration => $opts->{collaboration} || undef,  # Mark collaboration exchanges
            # Values: 'request_input', 'interrupt', 'checkpoint', etc.
            # Used by YaRN to identify and preserve collaboration exchanges
            # during context trimming. Set by Interact.pm and other tools
            # that pause for user input.
            unix_timestamp => time(),  # Keep Unix timestamp for backwards compatibility
        },
    };
    
    # Add tool_calls if provided (for assistant messages with tool execution)
    if ($opts && $opts->{tool_calls}) {
        $message->{tool_calls} = $opts->{tool_calls};
        log_debug('State::add_message', "Added tool_calls to message");
    }
    
    # Add tool_call_id if provided (for tool result messages)
    if ($opts && $opts->{tool_call_id}) {
        $message->{tool_call_id} = $opts->{tool_call_id};
        log_debug('State::add_message', "Added tool_call_id=$opts->{tool_call_id} to message");
    }
    
    # Add reasoning_content if provided (for DeepSeek thinking mode)
    if ($opts && $opts->{reasoning_content}) {
        $message->{reasoning_content} = $opts->{reasoning_content};
        log_debug('State::add_message', "Added reasoning_content to message");
    }

    # Add reasoning_details if provided (OpenAI Chat Completions format)
    # Used by OpenRouter/OpenAI-style providers; replayed on subsequent turns so
    # the model can continue its chain-of-thought across turns.
    if ($opts && $opts->{reasoning_details} && ref($opts->{reasoning_details}) eq 'ARRAY') {
        $message->{reasoning_details} = $opts->{reasoning_details};
        log_debug('State::add_message', "Added reasoning_details to message (" . scalar(@{$opts->{reasoning_details}}) . " items)");
    }

    # Add reasoning_blocks if provided (Anthropic native extended thinking format)
    # Replayed so Anthropic's thinking continuity holds across turns.
    if ($opts && $opts->{reasoning_blocks} && ref($opts->{reasoning_blocks}) eq 'ARRAY') {
        $message->{reasoning_blocks} = $opts->{reasoning_blocks};
        log_debug('State::add_message', "Added reasoning_blocks to message (" . scalar(@{$opts->{reasoning_blocks}}) . " blocks)");
    }

    # Add responses_reasoning_items if provided (OpenAI Responses API native format)
    # Required for OpenAI Responses chained reasoning across turns; without this
    # the provider has to start a new reasoning chain from scratch each turn.
    if ($opts && $opts->{responses_reasoning_items} && ref($opts->{responses_reasoning_items}) eq 'ARRAY') {
        $message->{responses_reasoning_items} = $opts->{responses_reasoning_items};
        log_debug('State::add_message', "Added responses_reasoning_items to message (" . scalar(@{$opts->{responses_reasoning_items}}) . " items)");
    }

    # Add provider response ID if available (for assistant messages)
    if ($role eq 'assistant' && $self->{lastGitHubCopilotResponseId}) {
        $message->{metadata}{providerResponseId} = $self->{lastGitHubCopilotResponseId};
    }
    
    # Calculate and tag with importance score
    # Pass the message index so first user message gets special treatment
    my $message_index = scalar(@{$self->{history}});
    $message->{_importance} = $self->calculate_message_importance($message, $message_index);
    
    # DEBUG: Log final message structure
    if (($ENV{CLIO_DEBUG} || $self->{debug}) && $role eq 'tool') {
        log_debug('SessionState', "State::add_message] Final tool message structure: " . "role=$message->{role}, " .
            "has_tool_call_id=" . (exists $message->{tool_call_id} ? 'YES' : 'NO') . ", " .
            "tool_call_id=" . ($message->{tool_call_id} // 'MISSING'));
    }
    
    # Add to active conversation history
    push @{$self->{history}}, $message;
    
    # Store ALL messages in YaRN for persistent recall
    my $thread_id = $self->{session_id};
    $self->{yarn}->create_thread($thread_id) unless $self->{yarn}->get_thread($thread_id);
    $self->{yarn}->add_to_thread($thread_id, $message);
    
    # Aggressively trim context to stay within safe token budget
    # Use prompt budget from model capabilities for model-aware trim threshold
    my $current_size = $self->get_conversation_size();

    # Threshold: model context window minus reserve for output and
    # estimation buffer. Previously this was int(max_tokens * 0.75) which
    # reserved 25% of context for output regardless of model. Now we use
    # compute_prompt_budget which uses the actual configured output
    # cap (max_output_tokens) plus the estimation buffer.
    #
    # For 1M context with 16K output (typical cloud provider): was 750K
    # threshold (25% reserved for output), now ~934K (16K + 50K buffer).
    # For 128K context with 16K output: was 96K, now ~104K.
    my $max_tokens = $self->{max_tokens} // 128000;  # Default to 128k if not set
    my $max_output = $self->{max_output_tokens}
                  // CLIO::Core::Defaults::DEFAULT_MAX_OUTPUT_TOKENS();
    my $trim_threshold = CLIO::Memory::TokenEstimator::compute_prompt_budget({
        max_context_window_tokens => $max_tokens,
        max_output_tokens         => $max_output,
    });

    if ($current_size > $trim_threshold) {
        if ($ENV{CLIO_DEBUG} || $self->{debug}) {
            log_debug('SessionState', "[STATE] Context size ($current_size tokens) exceeds prompt budget ($trim_threshold of $max_tokens max, $max_output output reserve), trimming...");
        }
        $self->trim_context();
    }
}

=head2 calculate_message_importance

Calculate importance score for a message.
Higher scores mean message is more important to preserve.

Factors:
- Role: user (1.5x), assistant with tool_calls (2.0x)
- Recency: exponential decay (older = less important)
- Keywords: error/bug/fix/critical (1.3x)
- Length: log scaling (longer = more detail)

Returns: Importance score (float, decays with age)

=cut

sub calculate_message_importance {
    my ($self, $message, $message_index) = @_;
    
    my $score = 1.0;
    
    # Recency factor (exponential decay)
    my $age = $self->message_age($message);
    $score *= exp(-$age / 10);  # Older messages decay
    
    # Role importance
    if ($message->{role} eq 'user') {
        $score *= 1.5;  # User messages always important
    }
    
    if ($message->{role} eq 'assistant' && $message->{tool_calls}) {
        $score *= 2.0;  # Tool calls are important
    }
    
    # Keyword detection
    if (defined $message->{content} && $message->{content} =~ /\b(error|bug|fix|critical|important|decision|warning)\b/i) {
        $score *= 1.3;
    }
    
    # Length indicates detail/importance
    my $length = length($message->{content} // '');
    if ($length > 0) {
        $score *= (1 + log($length) / 10);
    }
    
    return $score;
}

=head2 message_age

Calculate age of message in number of messages since it was added.

=cut

sub message_age {
    my ($self, $message) = @_;
    
    my $total = scalar(@{$self->{history}});
    
    # Find position of this message
    for my $i (0 .. $#{$self->{history}}) {
        if ($self->{history}->[$i] == $message) {
            return $total - $i;
        }
    }
    
    return $total;  # Fallback: treat as oldest
}

=head2 get_conversation_size

Calculate total token count of current conversation history.

Returns: Estimated token count

=cut

sub get_conversation_size {
    my ($self) = @_;
    return CLIO::Memory::TokenEstimator::estimate_messages_tokens($self->{history});
}

=head2 trim_context

Intelligently trim context when approaching token limits.
Preserves: system messages, recent messages (last 10), high-importance messages.
Moves trimmed messages to YaRN for later recall.

Also injects a notification message to inform the agent about what was trimmed
and how to recover the context.

=cut

sub trim_context {
    my ($self) = @_;
    
    my @messages = @{$self->{history}};
    return unless @messages > 15;  # Don't trim very short conversations
    
    # Scale keep_recent based on model context window.
    # Default 128k context: 10 messages. 1M context: ~78 messages.
    # This ensures large-context models retain proportionally more history.
    my $max_tokens = $self->{max_tokens} // 128000;
    my $keep_recent = int(10 * ($max_tokens / 128000));
    $keep_recent = 10 if $keep_recent < 10;     # Minimum 10 messages
    $keep_recent = 100 if $keep_recent > 100;    # Cap at 100 messages
    
    # Simple tail-preserving trim strategy:
    # Keep system messages + last N non-system messages.
    # The proactive trim in MessageValidator handles sophisticated compression
    # (thread_summary, user message preservation, budget-based walk).
    # This trim just ensures Session::State history stays bounded.
    
    # Separate system messages (prompt, previous trim notices) from conversation
    my @system = grep { defined $_->{role} && $_->{role} eq 'system' } @messages;
    my @non_system = grep { defined $_->{role} && $_->{role} ne 'system' } @messages;

    # Keep the most recent non-system messages (the tail of the conversation)
    my @recent = @non_system >= $keep_recent 
        ? @non_system[-$keep_recent .. -1] 
        : @non_system;
    
    my $before = scalar(@messages);
    my $dropped_count = scalar(@non_system) - scalar(@recent);
    
    # Nothing to trim
    return if $dropped_count <= 0;
    
    # Collect dropped messages for YaRN compression
    my $keep_start = scalar(@non_system) - scalar(@recent);
    my @dropped = @non_system[0 .. ($keep_start - 1)];
    
    # Find the most recent user message for task context
    my $last_user_msg;
    for my $msg (reverse @dropped) {
        if (($msg->{role} // '') eq 'user') {
            $last_user_msg = $msg;
            last;
        }
    }
    
    # Compress dropped messages with YaRN for context recovery
    my $compressed_summary = '';
    eval {
        require CLIO::Memory::YaRN;
        my $yarn = CLIO::Memory::YaRN->new();
        my $compressed = $yarn->compress_messages(\@dropped,
            original_task => $last_user_msg ? ($last_user_msg->{content} || '') : '',
        );
        if ($compressed && $compressed->{content}) {
            $compressed_summary = $compressed->{content};
        }
    };
    if ($@) {
        log_warning('SessionState', "YaRN compression in trim_context failed: $@");
    }
    
    # Build trim notification - include compressed summary if available
    my $trim_content;
    if ($compressed_summary) {
        $trim_content = "[CONTEXT TRIM: $dropped_count messages compressed]\n" .
            "Older messages summarized below. Recent $keep_recent messages preserved in full.\n\n" .
            $compressed_summary . "\n\n" .
            "To recover more context:\n" .
            "1. memory_operations(operation: 'retrieve', key: 'session_goals') for session goals\n" .
            "2. memory_operations(operation: 'recall_sessions', query: '<keywords>') for session history\n" .
            "3. git log and todo_operations(operation: 'read') to verify current state\n" .
            "DO NOT read handoff documents in ai-assisted/ - use the tools above instead.";
    } else {
        $trim_content = "[CONTEXT TRIM: $dropped_count messages archived]\n" .
            "Token limit approached. Older messages moved to YaRN archive.\n" .
            "Recent $keep_recent messages preserved.\n\n" .
            "To recover context, use these in order:\n" .
            "1. Your LTM patterns (already in system prompt) have project knowledge\n" .
            "2. memory_operations(operation: 'retrieve', key: 'session_progress') for recent progress\n" .
            "3. memory_operations(operation: 'recall_sessions', query: '<keywords>') for session history\n" .
            "4. git log and todo_operations(operation: 'read') to verify current state\n" .
            "DO NOT read handoff documents in ai-assisted/ - use the tools above instead.";
    }
    
    my $trim_notice = {
        role => 'system',
        content => $trim_content,
        _importance => 0.5,
    };
    
    # Reconstruct: system messages + trim notice + recent tail
    my @trimmed = (@system, $trim_notice, @recent);
    
    # Log trimming
    my $after = scalar(@trimmed);
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        use CLIO::Memory::TokenEstimator;
        my $before_tokens = CLIO::Memory::TokenEstimator::estimate_messages_tokens(\@messages);
        my $after_tokens = CLIO::Memory::TokenEstimator::estimate_messages_tokens(\@trimmed);
        log_info('SessionState', "Context trim: $before -> $after messages ($before_tokens -> $after_tokens tokens, " .
                     int(($after_tokens / $before_tokens) * 100) . "% retained)");
        log_debug('SessionState', "[STATE] Trim notification injected - agent notified of archived context");
    }
    
    # Update history (trimmed messages already in YaRN from add_message)
    $self->{history} = \@trimmed;
}

sub get_history {
    my ($self) = @_;
    return $self->{history};
}

sub cleanup {
    my ($self) = @_;
    unlink $self->{file} if -e $self->{file};
}

=head2 record_api_usage

Record API usage for billing tracking with GitHub Copilot multipliers.

Arguments:
- $usage: Hash with prompt_tokens, completion_tokens
- $model: Model name (optional, for multiplier lookup)

=cut

sub record_api_usage {
    my ($self, $usage, $model, $provider) = @_;
    
    return unless $usage && ref($usage) eq 'HASH';
    
    my $prompt_tokens = $usage->{prompt_tokens} || 0;
    my $completion_tokens = $usage->{completion_tokens} || 0;
    my $total_tokens = $usage->{total_tokens} || ($prompt_tokens + $completion_tokens);
    
    # Update session totals
    $self->{billing}{total_prompt_tokens} += $prompt_tokens;
    $self->{billing}{total_completion_tokens} += $completion_tokens;
    $self->{billing}{total_tokens} += $total_tokens;
    $self->{billing}{total_requests}++;
    
    # Track model and fetch multiplier
    my $multiplier = 0;
    if ($model) {
        $self->{billing}{model} = $model;
        
        # Fetch multiplier from GitHub Copilot API if using GitHub Copilot provider
        # No more hardcoded model name patterns!
        if ($provider && $provider eq 'github_copilot') {
            # Strip provider prefix for API lookup: "github_copilot/gpt-4.1" -> "gpt-4.1"
            # But skip if model has a different provider prefix (e.g. openrouter/...)
            my $api_model = $model;
            my $skip_billing = 0;
            require CLIO::Providers;
            if ($api_model =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i && CLIO::Providers::provider_exists($1)) {
                if ($1 ne 'github_copilot') {
                    # Model is routed to a different provider - skip GH billing lookup
                    $skip_billing = 1;
                }
                $api_model = $2;
            }
            
            unless ($skip_billing) {
                require CLIO::Core::GitHubCopilotModelsAPI;
                my $api = CLIO::Core::GitHubCopilotModelsAPI->new(debug => $self->{debug});
                my $billing_info = $api->get_model_billing($api_model);
                if ($billing_info && defined $billing_info->{multiplier}) {
                    $multiplier = $billing_info->{multiplier};
                    $self->{billing}{multiplier} = $multiplier;
                }
                if ($billing_info && $billing_info->{category}) {
                    $self->{billing}{category} = $billing_info->{category};
                }
                if ($billing_info && $billing_info->{vendor}) {
                    $self->{billing}{vendor} = $billing_info->{vendor};
                }
            }
        }
        # For non-GitHub-Copilot providers, multiplier stays 0 (no billing tracking)
    }
    
    # Record individual request with model and multiplier
    push @{$self->{billing}{requests}}, {
        timestamp => time(),
        model => $model || 'unknown',
        multiplier => $multiplier,
        prompt_tokens => $prompt_tokens,
        completion_tokens => $completion_tokens,
        total_tokens => $total_tokens,
    };
    
    # Charge the multiplier upfront on the FIRST credit-charging request so the user
    # sees an immediate count (not 0). ResponseHandler will reconcile this
    # with the first non-zero quota header delta to avoid double-counting.
    # After reconciliation, only quota header deltas drive the count.
    if ($multiplier > 0 && ($self->{billing}{total_premium_requests} || 0) == 0) {
        $self->{billing}{total_premium_requests} = $multiplier;
        $self->{billing}{_initial_premium_charged} = 1;  # Flag for reconciliation
        log_debug('SessionState', "Initial credit charge: ${multiplier}x (pending reconciliation with quota headers)");
    }
    
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        log_debug('SessionState', "Recorded API usage: " . "model=" . ($model || 'unknown') . ", " .
            "multiplier=${multiplier}x, " .
            "tokens=$total_tokens\n");
    }
}

=head2 get_billing_summary

Get a summary of billing usage for this session.

Returns:
- Hash with billing statistics

=cut

sub get_billing_summary {
    my ($self) = @_;
    
    return {
        total_requests => $self->{billing}{total_requests},
        total_premium_requests => $self->{billing}{total_premium_requests} || 0,
        total_prompt_tokens => $self->{billing}{total_prompt_tokens},
        total_completion_tokens => $self->{billing}{total_completion_tokens},
        total_tokens => $self->{billing}{total_tokens},
        requests => $self->{billing}{requests},
    };
}


=head2 _generate_fallback_name($text)

Generate a concise session name from user input text using simple truncation.
Used as a safety net when the AI doesn't provide a session title marker.

Returns a string of up to 50 characters, truncated at a word boundary.

=cut

sub _generate_fallback_name {
    my ($text) = @_;
    
    return undef unless defined $text && length($text) > 0;
    
    my $name = $text;
    $name =~ s/^\s+//;
    $name =~ s/\s+$//;
    $name =~ s/\s+/ /g;
    
    # Strip common filler phrases
    $name =~ s/^(?:hey|hi|hello|please|can you|could you|i want to|i need to|i'd like to|let's)\s+//i;
    
    $name = ucfirst($name);
    
    return undef if !defined($name) || length($name) < 3;
    return $name;
}

1;
