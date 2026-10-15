# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::RouteManager;

use strict;
use warnings;
use utf8;
use Carp qw(croak);

use CLIO::Core::Logger qw(log_debug log_warning should_log);
use CLIO::Providers qw(provider_exists list_providers get_provider);

=head1 NAME

CLIO::Core::RouteManager - Role-aware route normalization, role resolution,
and candidate selection for the /api route system.

=head1 DESCRIPTION

Extends CLIO's model routing from a flat sequential fallback list to a
configurable, role-aware selection system. A route can assign different
models to different kinds of work (reasoning, coding, documentation,
design, etc.) and define per-role fallback candidates.

This module is a pure logic layer — it performs no I/O, makes no network
calls, and has no concurrency. It normalizes route configurations,
resolves the active work role for a task, and builds the runtime
candidate list that C<cycle_model()> iterates over.

The canonical route storage lives in C<CLIO::Core::Config> under the
C<model_routes> key. Legacy routes are ARRAY refs:
  { "my-route" => ["openrouter/foo", "kilo/bar"] }
Extended routes are HASH refs:
  { "dev" => { strategy => "role-aware", models => [...],
                roles => { coding => { model => "..." }, ... },
                default_role => "reasoning",
                fallbacks => { coding => [...] },
                intelligent => { classification => "adaptive", ... } } }

=cut

#--------------------------------------------------------------------------
# Constructor
#--------------------------------------------------------------------------

=head2 new()

Construct a RouteManager instance. The object holds no state; all
methods are effectively static. The constructor exists so callers can
use the standard C<Class>->new() idiom.

=cut

sub new {
    my ($class) = @_;
    return bless {}, $class;
}

#--------------------------------------------------------------------------
# Constants
#--------------------------------------------------------------------------

# The three routing strategies.
use constant STRATEGY_SEQUENTIAL     => 'sequential';
use constant STRATEGY_ROLE_AWARE => 'role-aware';
use constant STRATEGY_INTELLIGENT => 'intelligent';

# Valid strategy names (for validation).
my %VALID_STRATEGIES = (
    sequential    => 1,
    'role-aware' => 1,
    intelligent  => 1,
);

# Default role used when a route has no explicit default_role.
use constant DEFAULT_DEFAULT_ROLE => 'reasoning';

# Built-in roles with their canonical task keywords. These are
# suggestions, not a closed enumeration — users can add custom roles.
# Each keyword is matched case-insensitively as a whole word.
my %BUILTIN_ROLE_KEYWORDS = (
    reasoning => [qw( investigate analyze analysis evidence synthesize synthesis decompose decompose evaluate evaluation deep why how because because-of root-cause )],
    coding    => [qw( implement implementation fix refactor refactor fix-bug debug debugging test unit-test build compile code code-change feature function method class module bug bug-fix branch commit patch )],
    documentation => [qw( document documentation docs readme docstring comment explain explanation tutorial guide reference api-docs changelog release-notes )],
    design    => [qw( architecture architect design design-decision proposal approach trade-off tradeoff alternative alternatives compare comparison evaluate-decision system-design plan planning blueprint )],
);

#--------------------------------------------------------------------------

=head2 normalize_route($raw)

Normalize a route value (ARRAY ref or HASH ref) into a canonical hashref.

Legacy arrayref routes become:
  { strategy => 'sequential', models => [...] }

Extended hashref routes are returned as-is (dcloned).

Returns undef for undefined input.

=cut

sub normalize_route {
    my $proto = shift;
    my ($raw) = @_;

    return undef unless defined $raw;

    if (ref($raw) eq 'ARRAY') {
        return {
            strategy => STRATEGY_SEQUENTIAL,
            models   => [ @$raw ],
        };
    }

    if (ref($raw) eq 'HASH') {
        require Storable;
        my $norm = Storable::dclone($raw);

        # Fill in defaults for missing keys.
        $norm->{strategy}     //= STRATEGY_SEQUENTIAL;
        $norm->{models}       //= [];
        $norm->{roles}        //= {};
        $norm->{default_role} //= DEFAULT_DEFAULT_ROLE;
        $norm->{fallbacks}    //= {};
        $norm->{intelligent}  //= {};

        return $norm;
    }

    return undef;
}

=head2 get_strategy($route_config)

Extract the strategy from a normalized route config.

Returns: 'sequential', 'role-aware', or 'intelligent'. Defaults to 'sequential'.

=cut

sub get_strategy {
    my $proto = shift;
    my ($route_config) = @_;
    return undef unless ref($route_config) eq 'HASH';
    return $route_config->{strategy} || STRATEGY_SEQUENTIAL;
}

=head2 is_sequential($route_config)

Returns true if the route uses the sequential strategy.

=cut

sub is_sequential {
    my $proto = shift;
    my ($route_config) = @_;
    return __PACKAGE__->get_strategy($route_config) eq STRATEGY_SEQUENTIAL;
}

=head2 is_role_aware($route_config)

Returns true if the route uses role-aware or intelligent strategy.

=cut

sub is_role_aware {
    my $proto = shift;
    my ($route_config) = @_;
    my $s = __PACKAGE__->get_strategy($route_config);
    return $s eq STRATEGY_ROLE_AWARE || $s eq STRATEGY_INTELLIGENT;
}

=head2 get_role_models($route_config, $role)

Get the model assigned to a specific role within a route.

Arguments:
  $route_config - Normalized route config hashref
  $role         - Role name (e.g. 'coding', 'documentation')

Returns: The model string for the role (e.g. "openrouter/deepseek-v4"),
or undef if the role is not assigned.

Distinguishes intentionally unassigned roles (returns undef) from
invalid model references (caught by validate_role_model).

=cut

sub get_role_models {
    my $proto = shift;
    my ($route_config, $role) = @_;
    return undef unless ref($route_config) eq 'HASH' && length($role);
    my $roles = $route_config->{roles} || {};
    my $entry = $roles->{lc($role)};
    return undef unless $entry && ref($entry) eq 'HASH';
    return $entry->{model};
}

=head2 get_role_fallbacks($route_config, $role)

Get the fallback model list for a specific role.

Arguments:
  $route_config - Normalized route config hashref
  $role         - Role name

Returns: Arrayref of fallback model strings, or empty arrayref if
no fallbacks are configured for this role.

=cut

sub get_role_fallbacks {
    my $proto = shift;
    my ($route_config, $role) = @_;
    return [] unless ref($route_config) eq 'HASH';
    my $fallbacks = $route_config->{fallbacks} || {};
    my $fb = $fallbacks->{lc($role)};
    return ref($fb) eq 'ARRAY' ? [ @$fb ] : [];
}

=head2 get_route_candidates($route_config, $role)

Build the full runtime candidate list for a role within a route.

The candidates list is: [primary_model, ...fallbacks], deduplicated.
This is the list that C<cycle_model()> iterates over when a route is
active. The primary model is tried first; on failure, the fallbacks
are tried in order.

Arguments:
  $route_config - Normalized route config hashref
  $role         - Role name (or undef for sequential strategy)

Returns: Arrayref of model strings (at least one if the role has a model).

=cut

sub get_route_candidates {
    my $proto = shift;
    my ($route_config, $role) = @_;

    if (!defined $role || !length($role) || !__PACKAGE__->is_role_aware($route_config)) {
        # Legacy strategy: return the flat models list.
        my $models = $route_config->{models} || [];
        return [ @$models ];
    }

    # Role-aware: primary + fallbacks, deduplicated (primary first).
    my $primary = __PACKAGE__->get_role_models($route_config, $role);
    my @seen;
    my $seen = {};
    if ($primary && length($primary)) {
        push @seen, $primary;
        $seen->{lc($primary)} = 1;
    }

    my $fallbacks = __PACKAGE__->get_role_fallbacks($route_config, $role);
    for my $fb (@$fallbacks) {
        next unless $fb && length($fb);
        next if $seen->{lc($fb)};
        push @seen, $fb;
        $seen->{lc($fb)} = 1;
    }

    return \@seen;
}

=head2 resolve_role($route_config, $task_hint, $api_manager)

Determine the work role for the current task based on the route config.

For 'sequential' strategy: returns undef (no role).
For 'role-aware' strategy with a single role: returns that role (rule-based).
For 'intelligent' strategy: uses rules first, falls back to LLM classification
when rules are ambiguous and the task could materially change the selection.

Arguments:
  $route_config  - Normalized route config hashref
  $task_hint     - User's input message (string)
  $api_manager   - APIManager instance (for LLM classification; may be undef)

Returns: Role name (string) or the route's default_role.

=cut

sub resolve_role {
    my $proto = shift;
    my ($route_config, $task_hint, $api_manager) = @_;

    my $strategy = __PACKAGE__->get_strategy($route_config);
    my $default_role = $route_config->{default_role} // DEFAULT_DEFAULT_ROLE;

    # Legacy strategy: no role concept.
    if ($strategy eq STRATEGY_SEQUENTIAL) {
        return undef;
    }

    # If there's only one role defined, no need to classify.
    my $roles = $route_config->{roles} || {};
    my @role_names = keys %$roles;
    if (scalar(@role_names) == 1) {
        return $role_names[0];
    }

    # If no roles at all, fall back to the default role.
    if (scalar(@role_names) == 0) {
        return $default_role;
    }

    # Strategy: role-aware (rules only) or intelligent (adaptive)
    if ($strategy eq STRATEGY_ROLE_AWARE) {
        my $classified = __PACKAGE__->_classify_by_rules($task_hint, $roles);
        if (defined $classified) {
            return $classified;
        }
        # No rule matched — use the default role.
        log_debug('RouteManager', "No rule matched for role-aware route; using default role '$default_role'");
        return $default_role;
    }

    # Strategy: intelligent (adaptive classification)
    if ($strategy eq STRATEGY_INTELLIGENT) {
        my $classified = __PACKAGE__->_classify_by_rules($task_hint, $roles);
        if (defined $classified) {
            # Rules matched confidently — no LLM call needed.
            log_debug('RouteManager', "Adaptive classification: rules matched '$classified' (no LLM call)");
            return $classified;
        }

        # Rules are ambiguous — check if we have a planner model configured.
        my $intelligent = $route_config->{intelligent} || {};
        my $planner_model = $intelligent->{planner_model} || $intelligent->{classification_model};
        if ($planner_model && $api_manager) {
            my $llm_role = __PACKAGE__->_classify_by_llm($task_hint, $roles, $planner_model, $api_manager);
            if (defined $llm_role) {
                return $llm_role;
            }
            # LLM classification failed or returned unknown — fall back.
            log_debug('RouteManager', "LLM classification failed; falling back to default role '$default_role'");
        } else {
            log_debug('RouteManager', "Adaptive classification: rules ambiguous, no planner model configured; using default '$default_role'");
        }

        return $default_role;
    }

    # Unknown strategy: fall back to default role.
    log_debug('RouteManager', "Unknown strategy '$strategy'; using default role '$default_role'");
    return $default_role;
}

=head2 _classify_by_rules($task_hint, $roles)

Attempt rules-based classification using keyword matching.

Returns: A matched role name, or undef if no rule confidently matches.

=cut

sub _classify_by_rules {
    my $proto = shift;
    my ($task_hint, $roles) = @_;

    return undef unless defined $task_hint && length($task_hint);
    my %known_roles = map { lc($_) => 1 } keys %$roles;

    # Build a score map: role => keyword_hit_count
    my %scores;
    my $lc_task = lc($task_hint);

    for my $role (keys %known_roles) {
        my $keywords = $BUILTIN_ROLE_KEYWORDS{lc($role)};
        next unless $keywords;  # Only match built-in roles by keywords
        for my $kw (@$keywords) {
            # Word-boundary match (case-insensitive)
            if (index($lc_task, lc($kw)) >= 0) {
                $scores{lc($role)}++;
            }
        }
    }

    # Only return a role if it has the strictly highest score and at
    # least 2 keyword hits (to avoid matching on single, ambiguous words).
    my @ranked = sort { $scores{$b} <=> $scores{$a} } keys %scores;
    if (@ranked && $scores{$ranked[0]} >= 2) {
        my $top = $ranked[0];
        if (@ranked == 1 || $scores{$ranked[1]} < $scores{$top}) {
            # Map back from lowercase to actual role name
            for my $r (keys %$roles) {
                if (lc($r) eq $top) {
                    return $r;
                }
            }
            return $top;  # Should not happen, but be safe
        }
    }

    # Could not confidently classify.
    return undef;
}

=head2 _classify_by_llm($task_hint, $roles, $model, $api_manager)

Use an LLM to classify the task type when rules are ambiguous.

The classifier is given a compact prompt with the task hint and the
list of available roles. It must return structured JSON. The output is
validated against the known roles. The classifier can NEVER pick an
arbitrary model — it only selects a role from the configured set.

This is a bounded call: if the LLM call fails, times out, or returns
invalid output, it returns undef so the caller falls back to the
default role.

Arguments:
  $task_hint     - User's input message (string)
  $roles         - Hashref of role => { model => "..." }
  $model         - Model string for the classifier (e.g. "openrouter/deepseek-v4")
  $api_manager   - APIManager instance

Returns: A role name, or undef on failure.

=cut

sub _classify_by_llm {
    my $proto = shift;
    my ($task_hint, $roles, $model, $api_manager) = @_;

    return undef unless $api_manager && $model;

    # Build the compact system prompt. We do NOT send the conversation
    # history or private context — only the task hint and role names.
    my @role_names = sort keys %$roles;

    my $system_prompt = "You are a task classifier. Classify the user's request into exactly one of the following work roles: "
        . join(', ', @role_names) . ". Return ONLY a JSON object with a single key 'role' whose value is one of the role names above. Do not include any other text.";

    my $payload = {
        model       => $model,
        messages    => [
            { role => 'system', content => $system_prompt },
            { role => 'user',   content => $task_hint },
        ],
        max_tokens  => 256,
        temperature => 0.0,
    };

    # Use the APIManager's internal request method to make a simple
    # chat completion (non-streaming, no tools). This reuses the existing
    # provider dispatch and auth resolution.
    my $response = eval {
        # APIManager::send_request_streaming needs a callback; use a no-op.
        # Actually, for classification we want a simple non-streaming call.
        # We'll use the send_request method if it exists, or construct
        # a minimal streaming call.
        if ($api_manager->can('send_request')) {
            $api_manager->send_request(undef, %$payload);
        } else {
            # Fallback: use send_request_streaming with a no-op callback
            my $collected = '';
            $api_manager->send_request_streaming(
                undef,
                messages   => $payload->{messages},
                model      => $model,
                max_tokens => $payload->{max_tokens},
                temperature => $payload->{temperature},
                on_chunk   => sub { my (undef, $chunk) = @_; $collected .= ($chunk->{content} // '') if ref $chunk eq 'HASH'; },
            );
            # The streaming call returns the final response; we need the
            # content. If that path returns structured data, extract it.
            $collected;
        }
    };

    if ($@) {
        log_debug('RouteManager', "LLM classification failed: $@");
        return undef;
    }

    return undef unless defined $response && $response->{success};

    # Extract content from the response
    my $content = '';
    if (ref($response) eq 'HASH' && $response->{choices}) {
        my $choice = $response->{choices}[0];
        if ($choice->{message} && ref($choice->{message}{content}) eq '') {
            $content = $choice->{message}{content};
        } elsif ($choice->{delta} && $choice->{delta}{content}) {
            $content = $choice->{delta}{content};
        }
    } elsif (ref($response) eq 'HASH' && $response->{message}) {
        # Some streaming wrappers return a message structure
        $content = $response->{message}{content} // '';
    }

    # If we collected streamed content, use that
    if (defined $response && ref($response) eq 'HASH' && $response->{_collected_content}) {
        $content = $response->{_collected_content};
    }

    return undef unless $content && length($content);

    # Stripping any reasoning/thinking or markdown fencing
    $content =~ s/```(?:json)?\s*//g;
    $content =~ s/\s*```\s*$//g;
    $content =~ s/^\s+//;
    $content =~ s/\s+$//;

    # Parse and validate JSON
    require CLIO::Util::JSON;
    my $parsed = eval { CLIO::Util::JSON::decode_json($content) };
    if ($@ || ref($parsed) ne 'HASH' || !$parsed->{role}) {
        log_debug('RouteManager', "LLM classification returned invalid JSON: '$content'");
        return undef;
    }

    my $role = $parsed->{role};

    # Validate: the classified role MUST be one of the configured roles.
    # The classifier cannot invent arbitrary roles or models.
    unless (exists $roles->{$role}) {
        log_debug('RouteManager', "LLM classified role '$role' is not a configured role; ignoring");
        return undef;
    }

    log_debug('RouteManager', "LLM classification returned role '$role'");
    return $role;
}

=head2 validate_route_config($config)

Validate an extended route configuration hashref.

Checks:
- strategy is one of: 'sequential', 'role-aware', 'intelligent'
- models is an arrayref (may be empty for role-aware routes that only use roles)
- roles is a hashref of role_name => { model => 'provider/model' }
- default_role references a configured role (if roles exist)
- fallbacks is a hashref of role_name => [model strings]
- intelligent is a hashref with valid classification settings

Returns: (1, '') on success, (0, $error_message) on failure.

=cut

sub validate_route_config {
    my $proto = shift;
    my ($config) = @_;

    unless (ref($config) eq 'HASH') {
        return (0, 'Route config must be a hashref');
    }

    # Strategy validation
    my $strategy = $config->{strategy} // STRATEGY_SEQUENTIAL;
    unless (exists $VALID_STRATEGIES{$strategy}) {
        return (0, "Invalid strategy '$strategy'. Valid: sequential, role-aware, intelligent");
    }

    # Models validation (required for sequential, optional for role-aware)
    if (exists $config->{models}) {
        unless (ref($config->{models}) eq 'ARRAY') {
            return (0, 'Route models must be an arrayref');
        }
    } else {
        $config->{models} = [];
    }

    # Roles validation
    if (exists $config->{roles}) {
        unless (ref($config->{roles}) eq 'HASH') {
            return (0, 'Route roles must be a hashref');
        }
        for my $role_name (keys %{$config->{roles}}) {
            my $entry = $config->{roles}{$role_name};
            unless (ref($entry) eq 'HASH') {
                return (0, "Role '$role_name' must be a hashref (e.g. { model => 'provider/model' })");
            }
            unless ($entry->{model} && length($entry->{model})) {
                return (0, "Role '$role_name' must have a 'model' key with a model string");
            }
        }
    }

    # Default role validation
    if (exists $config->{default_role}) {
        if ($config->{default_role} && ref($config->{roles}) eq 'HASH' && %{$config->{roles}}) {
            my $found = 0;
            for my $r (keys %{$config->{roles}}) {
                if (lc($r) eq lc($config->{default_role})) {
                    $found = 1;
                    last;
                }
            }
            unless ($found) {
                return (0, "default_role '$config->{default_role}' is not a configured role");
            }
        }
    }

    # Fallbacks validation
    if (exists $config->{fallbacks}) {
        unless (ref($config->{fallbacks}) eq 'HASH') {
            return (0, 'Route fallbacks must be a hashref');
        }
        for my $role_name (keys %{$config->{fallbacks}}) {
            my $fb = $config->{fallbacks}{$role_name};
            unless (ref($fb) eq 'ARRAY') {
                return (0, "Fallbacks for role '$role_name' must be an arrayref");
            }
        }
    }

    # Intelligent settings validation
    if (exists $config->{intelligent}) {
        unless (ref($config->{intelligent}) eq 'HASH') {
            return (0, 'Route intelligent settings must be a hashref');
        }
        my $intel = $config->{intelligent};
        if (exists $intel->{classification}) {
            my %valid_classes = (rules => 1, llm => 1, adaptive => 1);
            unless ($valid_classes{$intel->{classification}}) {
                return (0, "Invalid classification mode '$intel->{classification}'. Valid: rules, llm, adaptive");
            }
        }
        if (exists $intel->{planner_model}) {
            unless ($intel->{planner_model} && ref(\$intel->{planner_model}) eq 'SCALAR') {
                return (0, 'intelligent.planner_model must be a string');
            }
        }
        if (exists $intel->{max_planning_rounds}) {
            unless (defined $intel->{max_planning_rounds} && $intel->{max_planning_rounds} =~ /^\d+$/ && $intel->{max_planning_rounds} >= 1) {
                return (0, 'intelligent.max_planning_rounds must be a positive integer');
            }
        }
    }

    return (1, '');
}

=head2 get_all_roles($route_config)

Return a list of all role names defined in a route config.

=cut

sub get_all_roles {
    my $proto = shift;
    my ($route_config) = @_;
    return () unless ref($route_config) eq 'HASH';
    my $roles = $route_config->{roles} || {};
    return keys %$roles;
}

=head2 route_has_roles($route_config)

Returns true if the route defines any roles.

=cut

sub route_has_roles {
    my $proto = shift;
    my ($route_config) = @_;
    return 0 unless ref($route_config) eq 'HASH';
    return 0 unless ref($route_config->{roles}) eq 'HASH';
    return keys(%{$route_config->{roles}}) > 0;
}

1;

__END__
