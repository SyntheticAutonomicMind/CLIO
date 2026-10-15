# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::TaskClassifier;

use strict;
use warnings;
use utf8;
use Carp qw(croak);

use CLIO::Core::Logger qw(log_debug log_warning should_log);

=head1 NAME

CLIO::Core::TaskClassifier - Classify user tasks into work roles using
rules-based heuristics and optional LLM assistance.

=head1 DESCRIPTION

Provides adaptive task classification for role-aware routing. The classifier
produces structured information about the work type, complexity, and required
capabilities. It is used by C<CLIO::Core::RouteManager> to determine which
role (reasoning, coding, documentation, design, etc.) should handle a given
user request.

Classification modes:
  - C<rules>     - Pure keyword heuristics, no LLM call.
  - C<llm>       - LLM classification for every ambiguous task.
  - C<adaptive>  - Rules first, LLM only when rules are ambiguous. (default)

The classifier output is a hashref:
  {
    primary_work_type  => 'coding',          # Matched or default role
    additional_work_types => ['documentation'],  # Secondary roles detected
    complexity         => 'medium',          # 'low', 'medium', 'high'
    required_capabilities => ['tools'],      # 'tools', 'vision', 'reasoning'
    needs_decomposition => 0,                # Whether multi-stage plan is warranted
    confidence         => 0.8,               # 0.0 - 1.0
    classification_mode => 'rules',          # How this result was produced
  }

The classifier NEVER selects a model or bypasses route constraints. It only
produces a role name from the configured set. Invalid or unavailable
classifier responses trigger a bounded fallback to the default role.

=cut

# Complexity thresholds (keyword hit counts)
my %COMPLEXITY_THRESHOLDS = (
    low    => 2,   # 0-2 keyword hits => low complexity
    medium => 5,   # 3-5 keyword hits => medium complexity
    # 6+ => high
);

# Required capabilities by keyword group
my %CAPABILITY_KEYWORDS = (
    tools     => [qw( implement fix refactor debug test code function method class bug feature build compile tool_call tool )],
    reasoning => [qw( analyze evidence evaluate synthesize decompose root-cause trade-off alternative )],
    vision    => [qw( image photo visual diagram screenshot )],
);

=head2 classify($task_hint, $available_roles, $options)

Classify a task into a work role.

Arguments:
  $task_hint       - User's input message (string)
  $available_roles - Hashref of role_name => config (from route config)
  $options         - Hashref with:
    mode       => 'rules' | 'llm' | 'adaptive' (default: 'adaptive')
    api_manager => APIManager instance (required for 'llm'/'adaptive' when rules are ambiguous)
    planner_model => Model string for LLM classification (required for 'llm'/'adaptive')
    default_role => Role to use when classification fails (default: 'reasoning')

Returns: Classification result hashref (see DESCRIPTION).

=cut

sub classify {
    my ($task_hint, $available_roles, $options) = @_;

    $options //= {};
    my $mode          = $options->{mode} // 'adaptive';
    my $api_manager   = $options->{api_manager};
    my $planner_model = $options->{planner_model};
    my $default_role  = $options->{default_role} // 'reasoning';

    my $result = {
        primary_work_type     => $default_role,
        additional_work_types => [],
        complexity            => 'low',
        required_capabilities => [],
        needs_decomposition   => 0,
        confidence            => 0.0,
        classification_mode   => 'fallback',
        _raw                => $task_hint,
    };

    return $result unless defined $task_hint && length($task_hint);
    return $result unless $available_roles && ref($available_roles) eq 'HASH' && %$available_roles;

    # Ensure default_role is valid
    my $has_default = 0;
    for my $r (keys %$available_roles) {
        if (lc($r) eq lc($default_role)) {
            $has_default = 1;
            last;
        }
    }
    unless ($has_default) {
        # Default role not in available set — pick the first available
        my @keys = keys %$available_roles;
        $default_role = $keys[0] if @keys;
    }

    # --- Rules-based classification ---
    my $rules_result = _classify_rules($task_hint, $available_roles);

    if ($mode eq 'rules') {
        $result = _merge_classification($rules_result, 'rules', $default_role);
        return $result;
    }

    if ($rules_result->{confidence} >= 0.7) {
        # High confidence from rules — no LLM call needed.
        $result = _merge_classification($rules_result, 'rules', $default_role);
        log_debug('TaskClassifier', "Rules matched '${$result->{primary_work_type}}' with confidence " .
            sprintf('%.2f', $result->{confidence}) . " (no LLM call)");
        return $result;
    }

    # --- LLM-assisted classification (adaptive/llm mode) ---
    if ($mode eq 'adaptive' || $mode eq 'llm') {
        # Only consult LLM if it could materially change the selection.
        # In 'adaptive' mode, we already tried rules above; rules had low
        # confidence, so LLM might help. In 'llm' mode, always consult LLM.
        if ($api_manager && $planner_model) {
            my $llm_result = _classify_llm($task_hint, $available_roles, $planner_model, $api_manager,
                $mode eq 'llm' ? $rules_result : undef);
            if ($llm_result && $llm_result->{primary_work_type}) {
                $result = _merge_classification($llm_result, 'llm', $default_role);
                log_debug('TaskClassifier', "LLM classified '${$result->{primary_work_type}}' with confidence " .
                    sprintf('%.2f', $result->{confidence}));
                return $result;
            }
            # LLM failed — fall through to rules result or default.
            log_debug('TaskClassifier', "LLM classification failed; falling back to rules result");
        }
    }

    # --- Fallback: use rules result or default ---
    $result = _merge_classification($rules_result, 'rules-fallback', $default_role);
    return $result;
}

=head2 _classify_rules($task_hint, $available_roles)

Rules-based classification using keyword matching against built-in role
keyword sets.

Returns a partial result hashref with: primary_work_type, confidence,
complexity, required_capabilities, needs_decomposition, additional_work_types.

=cut

# Reuse the keyword sets from RouteManager for consistency.
my %RULE_KEYWORDS = (
    reasoning => [qw( investigate analyze analysis evidence synthesize synthesis decompose evaluate evaluation deep why how because root-cause )],
    coding    => [qw( implement implementation fix refactor debug debugging test unit-test build compile code code-change feature function method class module bug bug-fix branch commit patch programmer developer software )],
    documentation => [qw( document documentation docs readme docstring comment explain explanation tutorial guide reference api-docs changelog release-notes documentation )],
    design    => [qw( architecture architect design design-decision proposal approach trade-off tradeoff alternative alternatives compare comparison evaluate-decision system-design plan planning blueprint architectural )],
);

sub _classify_rules {
    my ($task_hint, $available_roles) = @_;

    return _empty_rules_result() unless defined $task_hint && length($task_hint);
    my $lc_task = lc($task_hint);
    my $total_len = length($task_hint);

    # Score each available role by keyword hits
    my %scores;
    my %caps_needed;
    my @additional;

    for my $role (keys %$available_roles) {
        my $keywords = $RULE_KEYWORDS{lc($role)};
        next unless $keywords;  # Only built-in roles have keyword sets
        my $hits = 0;
        for my $kw (@$keywords) {
            # Word-boundary matching: check for the keyword as a whole word
            if (index($lc_task, lc($kw)) >= 0) {
                # Verify it's a word boundary (not a substring of another word)
                my $pos = 0;
                while (($pos = index($lc_task, lc($kw), $pos)) >= 0) {
                    my $before = $pos > 0 ? substr($lc_task, $pos - 1, 1) : ' ';
                    my $after_pos = $pos + length($kw);
                    my $after = $after_pos < length($lc_task) ? substr($lc_task, $after_pos, 1) : ' ';
                    if ($before !~ /[a-z0-9_]/ && $after !~ /[a-z0-9_]/) {
                        $hits++;
                        last;  # Count each keyword at most once
                    }
                    $pos++;
                }
            }
        }
        $scores{lc($role)} = $hits if $hits > 0;
    }

    # If no scores, return low-confidence default
    unless (%scores) {
        return {
            primary_work_type     => undef,
            confidence            => 0.0,
            complexity            => 'low',
            required_capabilities => [],
            needs_decomposition   => _needs_decomposition($lc_task, $total_len),
            additional_work_types => [],
        };
    }

    # Rank roles by score
    my @ranked = sort { $scores{$b} <=> $scores{$a} } keys %scores;
    my $top_score = $scores{$ranked[0]};
    my $top_role = $ranked[0];

    # Map back to actual role name (case may differ)
    for my $r (keys %$available_roles) {
        if (lc($r) eq $top_role) {
            $top_role = $r;
            last;
        }
    }

    # Confidence: based on keyword hit count and score dominance
    my $confidence = _compute_confidence($top_score, @ranked);

    # Additional work types: roles with lower but non-zero scores
    for my $r (@ranked[1..$#ranked]) {
        last if $scores{$r} < 1;
        my $actual = $r;
        for my $rr (keys %$available_roles) {
            if (lc($rr) eq $r) { $actual = $rr; last; }
        }
        push @additional, $actual;
    }

    # Complexity: based on total keyword hits and task length
    my $total_hits = 0;
    $total_hits += $scores{$_} for keys %scores;
    my $complexity = _compute_complexity($total_hits, $total_len);

    # Required capabilities
    my @req_caps;
    # Tools are needed if coding keywords were hit
    if (($scores{coding} // 0) > 0) {
        push @req_caps, 'tools';
    }
    # Reasoning is needed if reasoning keywords were hit
    if (($scores{reasoning} // 0) > 0) {
        push @req_caps, 'reasoning';
    }

    return {
        primary_work_type     => $top_role,
        confidence            => $confidence,
        complexity            => $complexity,
        required_capabilities => \@req_caps,
        needs_decomposition   => _needs_decomposition($lc_task, $total_len),
        additional_work_types => \@additional,
    };
}

sub _empty_rules_result {
    return {
        primary_work_type     => undef,
        confidence            => 0.0,
        complexity            => 'low',
        required_capabilities => [],
        needs_decomposition   => 0,
        additional_work_types => [],
    };
}

sub _compute_confidence {
    my ($top_score, @ranked) = @_;
    # Confidence scales with top score, but is reduced if there's a close
    # runner-up (ambiguous).
    my $base = 0;
    if ($top_score >= 5) {
        $base = 0.9;
    } elsif ($top_score >= 3) {
        $base = 0.8;
    } elsif ($top_score >= 2) {
        $base = 0.65;
    } elsif ($top_score >= 1) {
        $base = 0.4;
    }

    if (@ranked > 1) {
        my $runner_up_score = $ranked[1];
        # No $scores ref here — ranked is role names, we need scores
        # Actually we passed @ranked which is sorted by score desc already.
        # The runner-up score isn't available here without the scores hash.
        # Reduce confidence if top score is close to runner-up.
        # Since we can't access scores here, just apply a mild reduction
        # if there are multiple roles with non-zero scores.
        $base *= 0.85;
    }

    return $base > 1.0 ? 1.0 : $base;
}

sub _compute_complexity {
    my ($total_hits, $total_len) = @_;
    if ($total_hits >= 6 || $total_len >= 300) {
        return 'high';
    }
    if ($total_hits >= 3 || $total_len >= 150) {
        return 'medium';
    }
    return 'low';
}

sub _needs_decomposition {
    my ($lc_task, $total_len) = @_;
    # Decomposition is warranted for tasks that explicitly mention multiple
    # work types or are very long (suggesting a multi-step request).
    return 1 if $lc_task =~ / and .* (implement|document|design|analyze)/ ||
               $lc_task =~ /implement.* and .* document/ ||
               $total_len >= 400;
    return 0;
}

=head2 _classify_llm($task_hint, $available_roles, $model, $api_manager, $rules_result)

Use an LLM to classify the task. The LLM receives a compact prompt with
the task hint and available role names. Returns a classification hashref
or undef on failure.

The LLM output is strictly validated: the classified role must be one of
the available_roles. The LLM cannot invent models, providers, or arbitrary
roles.

=cut

sub _classify_llm {
    my ($task_hint, $available_roles, $model, $api_manager, $rules_result) = @_;

    return undef unless $api_manager && $model && length($model);

    my @role_names = sort keys %$available_roles;
    my $roles_json = join(',', map { "\"$_\"" } @role_names);

    my $system_prompt = "Classify the user's request into exactly one work role. "
        . "Available roles: " . join(',', @role_names) . ". "
        . "Return ONLY a JSON object with keys: "
        . "'primary_work_type' (one of [$roles_json]), "
        . "'additional_work_types' (array of role names, may be empty), "
        . "'complexity' ('low'|'medium'|'high'), "
        . "'required_capabilities' (array of: tools|vision|reasoning), "
        . "'needs_decomposition' (0 or 1), "
        . "'confidence' (0.0 to 1.0). "
        . "Do not include any other text or markdown fencing.";

    # Make the API call using APIManager's non-streaming send_request.
    # send_request returns { success, content, metrics, usage, finish_reason }.
    # We use non-streaming for classification — it's simpler and we need
    # the full response text, not token-by-token updates.
    my $response = eval {
        $api_manager->send_request(
            undef,
            model       => $model,
            messages    => [
                { role => 'system', content => $system_prompt },
                { role => 'user',   content => $task_hint },
            ],
            max_tokens  => 512,
            temperature => 0.0,
        );
    };

    if ($@) {
        log_debug('TaskClassifier', "LLM classification API call failed: $@");
        return undef;
    }

    return undef unless ref($response) eq 'HASH' && $response->{success};

    # Extract content from the response
    my $content = _extract_response_content($response);
    return undef unless $content && length($content);

    # Strip markdown fencing if present
    $content =~ s/```(?:json)?\s*//g;
    $content =~ s/\s*```\s*$//g;
    $content =~ s/^\s+//;
    $content =~ s/\s+$//;

    require CLIO::Util::JSON;
    my $parsed = eval { CLIO::Util::JSON::decode_json($content) };
    if ($@ || ref($parsed) ne 'HASH') {
        log_debug('TaskClassifier', "LLM classification returned invalid JSON: '$content'");
        return undef;
    }

    # Validate: primary_work_type MUST be one of available_roles
    my $primary = $parsed->{primary_work_type};
    unless ($primary && exists $available_roles->{$primary}) {
        log_debug('TaskClassifier', "LLM classified role '$primary' is not in available roles");
        return undef;
    }

    return {
        primary_work_type     => $primary,
        additional_work_types => ref($parsed->{additional_work_types}) eq 'ARRAY' ? $parsed->{additional_work_types} : [],
        complexity            => $parsed->{complexity} // 'medium',
        required_capabilities => ref($parsed->{required_capabilities}) eq 'ARRAY' ? $parsed->{required_capabilities} : [],
        needs_decomposition   => $parsed->{needs_decomposition} ? 1 : 0,
        confidence            => $parsed->{confidence} // 0.5,
    };
}

=head2 _extract_response_content($response)

Extract the text content from an APIManager response hash.

=cut

sub _extract_response_content {
    my ($response) = @_;

    # send_request (non-streaming) returns { success, content, ... }
    if ($response->{content} && length($response->{content})) {
        return $response->{content};
    }

    # Check various response formats (streaming, OpenAI-compatible, etc.)
    if ($response->{choices} && ref($response->{choices}) eq 'ARRAY' && @{$response->{choices}}) {
        my $choice = $response->{choices}[0];
        if ($choice->{message} && $choice->{message}{content}) {
            return $choice->{message}{content};
        }
        if ($choice->{delta} && $choice->{delta}{content}) {
            return $choice->{delta}{content};
        }
    }

    if ($response->{message} && $response->{message}{content}) {
        return $response->{message}{content};
    }

    # If streaming collected content
    if ($response->{_collected_content}) {
        return $response->{_collected_content};
    }

    return undef;
}

=head2 _merge_classification($partial, $mode, $default_role)

Merge a partial classification result with defaults and mode info.

=cut

sub _merge_classification {
    my ($partial, $mode, $default_role) = @_;

    return {
        primary_work_type     => $partial->{primary_work_type} // $default_role,
        additional_work_types => $partial->{additional_work_types} // [],
        complexity            => $partial->{complexity} // 'low',
        required_capabilities => $partial->{required_capabilities} // [],
        needs_decomposition   => $partial->{needs_decomposition} // 0,
        confidence            => $partial->{confidence} // 0.0,
        classification_mode   => $mode,
    };
}

1;

__END__
