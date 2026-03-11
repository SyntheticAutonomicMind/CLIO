package CLIO::Core::API::MessageValidator;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(should_log log_debug log_info log_warning);
use CLIO::Memory::TokenEstimator qw(estimate_tokens);
use CLIO::Util::JSON qw(encode_json decode_json);
use POSIX qw(strftime);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::Core::API::MessageValidator - Message validation and truncation for API requests

=head1 DESCRIPTION

Extracted from APIManager.pm to handle message validation, tool-call pairing,
and conversation truncation. These operations ensure that message arrays sent
to AI providers conform to their requirements (no orphaned tool calls/results,
within token limits, etc.)

=head1 SYNOPSIS

    use CLIO::Core::API::MessageValidator;
    
    my $validated = CLIO::Core::API::MessageValidator::validate_tool_message_pairs($messages);
    my $errors = CLIO::Core::API::MessageValidator::preflight_validate($messages);
    my $truncated = CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => $messages,
        model_capabilities => $caps,
        tools              => $tools,
        token_ratio        => $ratio,
        config             => $config,
        api_base           => $api_base,
        debug              => $debug,
    );

=cut

use Exporter 'import';
our @EXPORT_OK = qw(
    validate_and_truncate
    validate_tool_message_pairs
    preflight_validate
);

=head2 validate_and_truncate

Validate messages and truncate to fit within token limits. Groups messages
into units (assistant+tool_calls+tool_results) to prevent orphaned pairs.
Uses YaRN compression for dropped messages when available.

Arguments (hash):
    messages           => ArrayRef of message objects (required)
    model_capabilities => HashRef from get_model_capabilities (optional)
    tools              => ArrayRef of tool definitions (optional)
    token_ratio        => Learned chars/token ratio (default: 2.5)
    config             => Config object (optional, for provider fallbacks)
    api_base           => API base URL (optional, for local model detection)
    debug              => Debug flag (optional)

Returns: ArrayRef of validated/truncated messages

=cut

sub validate_and_truncate {
    my (%args) = @_;
    
    my $messages = $args{messages} || [];
    my $caps = $args{model_capabilities};
    my $tools = $args{tools};
    my $token_ratio = $args{token_ratio} || 2.5;
    my $config = $args{config};
    my $api_base = $args{api_base} || '';
    my $debug = $args{debug};
    my $model = $args{model} || 'unknown';
    
    # Determine max prompt tokens
    my $max_prompt;
    if ($caps && $caps->{max_prompt_tokens}) {
        $max_prompt = $caps->{max_prompt_tokens};
    } else {
        my $provider = ($config && $config->can('get')) ? ($config->get('provider') || '') : '';
        
        if ($provider =~ /^(sam|llama\.cpp|lmstudio)$/i || 
            $api_base =~ m{localhost:[0-9]+}i ||
            $api_base =~ m{127\.0\.0\.1:[0-9]+}i) {
            $max_prompt = 32000;
        } else {
            $max_prompt = 128000;
        }
        
        log_debug('MessageValidator', "Using fallback token limit for $model: $max_prompt");
    }
    
    # Calculate tool token budget
    my $tool_tokens = _calculate_tool_tokens($tools);
    
    # Safety margins - account for estimation error, per-message overhead not captured,
    # and API-specific formatting tokens that aren't in our character count
    my $estimation_margin = int($max_prompt * 0.15);
    my $response_buffer = 8000;
    my $effective_limit = $max_prompt - $tool_tokens - ($estimation_margin + $response_buffer);
    $effective_limit = 1000 if $effective_limit < 1000;
    
    log_debug('MessageValidator', "Token budget: max=$max_prompt, tools=$tool_tokens, effective=$effective_limit");
    
    # Estimate token usage
    my $estimated_tokens = _estimate_tokens($messages);
    
    if ($estimated_tokens <= $effective_limit) {
        log_debug('MessageValidator', "Token validation: $estimated_tokens / $effective_limit tokens (OK)");
        return validate_tool_message_pairs($messages);
    }
    
    # Exceeds limit - need to truncate
    log_debug('MessageValidator', "Messages exceed token limit: $estimated_tokens > $effective_limit, truncating");

    # DIAGNOSTIC: Dump MessageValidator internal thresholds to /tmp (CLIO_TRIM_DIAG=1 to enable)
    if ($ENV{CLIO_TRIM_DIAG}) {
    eval {
        my $ts = POSIX::strftime('%Y%m%d_%H%M%S', localtime);
        my $diag_file = "/tmp/clio_trim_validator_${ts}_$$.log";
        if (open my $dfh, '>:encoding(UTF-8)', $diag_file) {
            print $dfh "MessageValidator TRUNCATION TRIGGERED\n";
            print $dfh "=" x 60, "\n";
            print $dfh "Timestamp: ", scalar(localtime), "\n";
            print $dfh "Model: $model\n";
            print $dfh "max_prompt (from caps): $max_prompt\n";
            print $dfh "tool_tokens: $tool_tokens\n";
            print $dfh "estimation_margin (15%): $estimation_margin\n";
            print $dfh "response_buffer: $response_buffer\n";
            print $dfh "effective_limit: $effective_limit\n";
            print $dfh "estimated_tokens: $estimated_tokens\n";
            print $dfh "overage: " . ($estimated_tokens - $effective_limit) . "\n";
            print $dfh "message_count: " . scalar(@$messages) . "\n";
            close $dfh;
            log_info('MessageValidator', "Validator thresholds dumped to $diag_file");
        }
    };
    }
    
    # Group messages into units
    my ($units_ref, $tool_id_map) = _group_into_units($messages);
    my @units = @$units_ref;
    
    log_debug('MessageValidator', "Grouped " . scalar(@$messages) . " messages into " . scalar(@units) . " units");
    
    # Extract system message and first user message
    my ($system_msg, $first_user_unit, $start_unit, $system_tokens, $first_user_tokens,
        $summary_unit, $summary_tokens, $gap_units) = 
        _extract_preserved_units(\@units);
    
    # Build conversation from newest to oldest
    my @conversation;
    my $current_tokens = $system_tokens + $first_user_tokens + $summary_tokens;
    my %included_tool_ids;
    # Extract previous summary content for merging into new compression
    my $previous_summary_content = '';
    if ($summary_unit && $summary_unit->{messages} && @{$summary_unit->{messages}}) {
        $previous_summary_content = $summary_unit->{messages}[0]{content} || '';
    }
    my @dropped_units;
    
    my @remaining = @units[$start_unit .. $#units];
    
    # Post-trim target: keep context at 50% of max to give headroom for the next burst
    # of work before hitting the ceiling again. Using effective_limit (83% of max) caused
    # immediate re-saturation on the very next large file read post-trim.
    my $post_trim_keep_limit = int($max_prompt * 0.50);
    $post_trim_keep_limit = $effective_limit if $post_trim_keep_limit < $effective_limit * 0.5;
    $post_trim_keep_limit = 32000 if $post_trim_keep_limit < 32000;
    log_debug('MessageValidator', "Post-trim keep target: $post_trim_keep_limit tokens (50% of $max_prompt)");

    # DIAGNOSTIC: Append post_trim_keep_limit to the validator diagnostic (CLIO_TRIM_DIAG=1 to enable)
    if ($ENV{CLIO_TRIM_DIAG}) {
    eval {
        my $ts = POSIX::strftime('%Y%m%d_%H%M%S', localtime);
        # Append to the most recent validator log
        my @logs = glob("/tmp/clio_trim_validator_*_$$.log");
        if (@logs) {
            my $latest = $logs[-1];
            if (open my $dfh, '>>:encoding(UTF-8)', $latest) {
                print $dfh "post_trim_keep_limit: $post_trim_keep_limit\n";
                print $dfh "system_tokens: $system_tokens\n";
                print $dfh "first_user_tokens: $first_user_tokens\n";
                print $dfh "summary_tokens: $summary_tokens\n";
                print $dfh "units_count: " . scalar(@units) . "\n";
                print $dfh "remaining_units: " . scalar(@remaining) . "\n";
                close $dfh;
            }
        }
    };
    }

    for my $unit (reverse @remaining) {
        if ($unit->{is_orphan_tool_result}) {
            log_debug('MessageValidator', "Skipping orphan tool_result unit (tool_id: $unit->{orphan_tool_id})");
            next;
        }
        
        if ($current_tokens + $unit->{tokens} <= $post_trim_keep_limit) {
            unshift @conversation, @{$unit->{messages}};
            $current_tokens += $unit->{tokens};
            for my $id (keys %{$unit->{tool_call_ids} || {}}) {
                $included_tool_ids{$id} = 1;
            }
        } else {
            push @dropped_units, $unit;
        }
    }
    
    # Compress dropped units
    # Create merged summary only if there are dropped messages to compress.
    # If nothing was dropped, preserve the existing summary as-is.
    my $summary_to_use;
    if (@dropped_units) {
        my $compressed = _compress_dropped(\@dropped_units, $first_user_unit, $debug, $previous_summary_content);
        $summary_to_use = $compressed;
    } elsif ($summary_unit && $summary_unit->{messages} && @{$summary_unit->{messages}}) {
        # No new drops - keep the existing summary intact
        $summary_to_use = $summary_unit->{messages}[0];
        log_debug('MessageValidator', "No dropped messages - preserving existing thread_summary");
    }
    
    # Post-truncation validation
    my @validated;
    for my $msg (@conversation) {
        my $is_tool_result = $msg->{tool_call_id} || ($msg->{role} && $msg->{role} eq 'tool');
        if ($is_tool_result && $msg->{tool_call_id} && !$included_tool_ids{$msg->{tool_call_id}}) {
            log_debug('MessageValidator', "Dropping orphaned tool_result after truncation");
            next;
        }
        push @validated, $msg;
    }
    
    # Combine: system + compressed + first user + validated
    my @truncated;
    push @truncated, $system_msg if $system_msg;
    push @truncated, $summary_to_use if $summary_to_use;
    push @truncated, @{$first_user_unit->{messages}} if $first_user_unit;
    push @truncated, @validated;
    
    if (should_log('DEBUG')) {
        my $final_tokens = _estimate_tokens(\@truncated);
        log_debug('MessageValidator', "Truncated: " . scalar(@$messages) . " -> " . scalar(@truncated) . 
            " messages, $final_tokens tokens");
    }
    
    return \@truncated;
}

=head2 validate_tool_message_pairs

Bidirectional validation of tool_calls and tool_results.
Removes orphaned tool_calls (strips from assistant messages) and
orphaned tool_results (removes entirely).

Arguments:
    $messages - ArrayRef of message objects

Returns: Validated ArrayRef

=cut

sub validate_tool_message_pairs {
    my ($messages) = @_;
    
    return [] unless $messages && @$messages;
    
    # Build bidirectional maps: tool_call_id -> assistant index, tool_call_id -> result index
    my %tc_id_to_assistant_idx;   # tool_call_id -> message index of assistant
    my %tr_id_to_result_idx;      # tool_call_id -> message index of tool result
    
    for (my $i = 0; $i < @$messages; $i++) {
        my $msg = $messages->[$i];
        if ($msg->{role} && $msg->{role} eq 'assistant' && 
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                $tc_id_to_assistant_idx{$tc->{id}} = $i if $tc->{id};
            }
        }
        if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
            $tr_id_to_result_idx{$msg->{tool_call_id}} = $i;
        }
    }
    
    # Identify orphaned tool_call IDs (no matching result) and orphaned result IDs (no matching call)
    my %orphaned_tc_ids;
    for my $tc_id (keys %tc_id_to_assistant_idx) {
        unless (exists $tr_id_to_result_idx{$tc_id}) {
            $orphaned_tc_ids{$tc_id} = 1;
            log_debug('MessageValidator', "Orphaned tool_call: $tc_id at message $tc_id_to_assistant_idx{$tc_id}");
        }
    }
    
    my %orphaned_result_indices;
    for my $tr_id (keys %tr_id_to_result_idx) {
        unless (exists $tc_id_to_assistant_idx{$tr_id}) {
            $orphaned_result_indices{$tr_id_to_result_idx{$tr_id}} = 1;
            log_debug('MessageValidator', "Orphaned tool_result: $tr_id at message $tr_id_to_result_idx{$tr_id}");
        }
    }
    
    # If no orphans, return original
    if (!keys %orphaned_tc_ids && !keys %orphaned_result_indices) {
        log_debug('MessageValidator', "Tool message validation: all pairs valid");
        return $messages;
    }
    
    # Rebuild: remove orphaned results entirely, selectively strip orphaned tool_calls
    my @validated;
    my $fixes = 0;
    for (my $i = 0; $i < @$messages; $i++) {
        my $msg = $messages->[$i];
        
        # Drop orphaned tool results
        if ($orphaned_result_indices{$i}) {
            log_debug('MessageValidator', "Removing orphaned tool_result at index $i");
            $fixes++;
            next;
        }
        
        # For assistant messages with tool_calls, strip only the orphaned ones
        if ($msg->{role} && $msg->{role} eq 'assistant' &&
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            
            my @kept_calls;
            my @dropped_calls;
            for my $tc (@{$msg->{tool_calls}}) {
                if ($tc->{id} && $orphaned_tc_ids{$tc->{id}}) {
                    push @dropped_calls, $tc->{id};
                } else {
                    push @kept_calls, $tc;
                }
            }
            
            if (@dropped_calls) {
                $fixes += scalar(@dropped_calls);
                log_debug('MessageValidator', "Stripped " . scalar(@dropped_calls) .
                    " orphaned tool_calls from assistant at index $i" .
                    " (kept " . scalar(@kept_calls) . ")");
                
                if (@kept_calls) {
                    # Keep assistant with remaining matched tool_calls
                    push @validated, {
                        %$msg,
                        tool_calls => \@kept_calls,
                    };
                } else {
                    # All tool_calls orphaned - keep as plain assistant
                    push @validated, { role => $msg->{role}, content => $msg->{content} || '' };
                }
                next;
            }
        }
        
        push @validated, $msg;
    }
    
    log_info('MessageValidator', "Fixed $fixes orphaned tool messages") if $fixes > 0;
    
    return \@validated;
}

=head2 preflight_validate

Lightweight pre-flight validation. Returns ArrayRef of error strings.

=cut

sub preflight_validate {
    my ($messages) = @_;
    
    return [] unless $messages && @$messages;
    
    my @errors;
    my %tool_call_ids;
    my %tool_result_ids;
    my %seen_ids;
    
    for (my $i = 0; $i < @$messages; $i++) {
        my $msg = $messages->[$i];
        my $role = $msg->{role} || '';
        
        if ($role eq 'assistant' && $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                my $id = $tc->{id};
                if ($id) {
                    push @errors, "Duplicate tool_call_id: $id" if $seen_ids{$id};
                    $seen_ids{$id} = $i;
                    $tool_call_ids{$id} = $i;
                }
            }
        }
        
        if ($role eq 'tool' && $msg->{tool_call_id}) {
            $tool_result_ids{$msg->{tool_call_id}} = $i;
        }
    }
    
    for my $id (keys %tool_call_ids) {
        push @errors, "Orphaned tool_call: $id" unless exists $tool_result_ids{$id};
    }
    for my $id (keys %tool_result_ids) {
        push @errors, "Orphaned tool_result: $id" unless exists $tool_call_ids{$id};
    }
    
    return \@errors;
}

# ================================================================
# Private helper functions
# ================================================================

sub _calculate_tool_tokens {
    my ($tools) = @_;
    return 0 unless $tools && ref($tools) eq 'ARRAY' && @$tools;
    
    my $total = 0;
    for my $tool (@$tools) {
        my $tool_json = eval { require JSON::PP; JSON::PP::encode_json($tool) };
        if ($tool_json) {
            $total += int(length($tool_json) / 2.5);
        } else {
            $total += 600;
        }
    }
    
    log_debug('MessageValidator', "Tool token budget: $total tokens for " . scalar(@$tools) . " tools");
    return $total;
}

sub _estimate_tokens {
    my ($messages) = @_;

    my $total = 0;
    for my $msg (@$messages) {
        # Per-message overhead: role field, message separators, formatting tokens
        # Every message has role + boundary tokens (~4)
        # Tool messages have additional name + tool_call_id fields (~8)
        $total += 4;                                                      # base overhead
        $total += 8 if $msg->{role} && $msg->{role} eq 'tool';           # tool-specific fields

        $total += estimate_tokens($msg->{content} || '');
        if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                my $json = eval { encode_json($tc) };
                $total += estimate_tokens($json || '');
            }
        }
    }
    return $total;
}

sub _group_into_units {
    my ($messages) = @_;

    my @units;
    my $current_unit;
    my %pending_tool_ids;
    my %tool_call_id_to_unit_idx;

    for my $msg (@$messages) {
        my $msg_tokens = estimate_tokens($msg->{content} || '') + 4;
        $msg_tokens += 8 if $msg->{role} && $msg->{role} eq 'tool';
        my $has_tool_calls = $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY' && @{$msg->{tool_calls}};
        my $is_tool_result = $msg->{tool_call_id} || ($msg->{role} && $msg->{role} eq 'tool');
        
        if ($has_tool_calls) {
            push @units, $current_unit if $current_unit;
            
            # Include tool_call JSON tokens in the unit's token count
            my $tc_tokens = 0;
            for my $tc (@{$msg->{tool_calls}}) {
                my $json = eval { encode_json($tc) } // '';
                $tc_tokens += estimate_tokens($json);
            }
            $current_unit = { messages => [$msg], tokens => $msg_tokens + $tc_tokens, tool_call_ids => {} };
            %pending_tool_ids = ();
            
            for my $tc (@{$msg->{tool_calls}}) {
                if ($tc->{id}) {
                    $pending_tool_ids{$tc->{id}} = 1;
                    $current_unit->{tool_call_ids}{$tc->{id}} = 1;
                    $tool_call_id_to_unit_idx{$tc->{id}} = scalar(@units);
                }
            }
        }
        elsif ($is_tool_result) {
            my $tool_id = $msg->{tool_call_id};
            
            if ($current_unit) {
                push @{$current_unit->{messages}}, $msg;
                $current_unit->{tokens} += $msg_tokens;
                delete $pending_tool_ids{$tool_id} if $tool_id;
                
                if (!keys %pending_tool_ids) {
                    push @units, $current_unit;
                    $current_unit = undef;
                }
            }
            elsif ($tool_id && exists $tool_call_id_to_unit_idx{$tool_id}) {
                my $parent_idx = $tool_call_id_to_unit_idx{$tool_id};
                if ($parent_idx < scalar(@units)) {
                    push @{$units[$parent_idx]{messages}}, $msg;
                    $units[$parent_idx]{tokens} += $msg_tokens;
                    log_debug('MessageValidator', "Merged orphan tool_result to unit $parent_idx");
                } else {
                    push @units, { messages => [$msg], tokens => $msg_tokens, 
                                   tool_call_ids => {}, is_orphan_tool_result => 1,
                                   orphan_tool_id => $tool_id };
                }
            }
            else {
                log_debug('MessageValidator', "Orphan tool_result: $tool_id (from truncation)");
                push @units, { messages => [$msg], tokens => $msg_tokens,
                               tool_call_ids => {}, is_orphan_tool_result => 1,
                               orphan_tool_id => $tool_id };
            }
        }
        else {
            if ($current_unit) {
                push @units, $current_unit;
                $current_unit = undef;
                %pending_tool_ids = ();
            }
            push @units, { messages => [$msg], tokens => $msg_tokens, tool_call_ids => {} };
        }
    }
    
    push @units, $current_unit if $current_unit;
    
    return (\@units, \%tool_call_id_to_unit_idx);
}

sub _extract_preserved_units {
    my ($units) = @_;
    
    my $system_msg;
    my $first_user_unit;
    my $start_unit = 0;
    my $system_tokens = 0;
    my $first_user_tokens = 0;
    my $summary_unit;         # Previous thread_summary (preserved across trims)
    my $summary_tokens = 0;
    my @gap_units;            # Other units between system msg and first user
    
    # Extract system message
    if (@$units && @{$units->[0]{messages}} && $units->[0]{messages}[0]{role} eq 'system') {
        $system_msg = $units->[0]{messages}[0];
        $system_tokens = $units->[0]{tokens};
        $start_unit = 1;
    }
    
    # Extract first user message
    # Uses _importance >= 10.0 (set by Session::State) if available, otherwise
    # falls back to the first user-role message found after system messages
    for my $i ($start_unit .. $#$units) {
        my $unit = $units->[$i];
        next unless $unit && $unit->{messages} && @{$unit->{messages}};
        
        my $first_msg = $unit->{messages}[0];
        if ($first_msg->{role} && $first_msg->{role} eq 'user') {
            $first_user_unit = $unit;
            $first_user_tokens = $unit->{tokens};
            $start_unit = $i + 1;
            log_debug('MessageValidator', "Preserving first user message (importance=" . 
                ($first_msg->{_importance} // 'n/a') . ", tokens=$first_user_tokens)");
            last;
        } else {
            # Check if this is an old thread_summary - preserve it separately
            my $content = $first_msg->{content} || '';
            if ($content =~ /<thread_summary>/) {
                $summary_unit = $unit;
                $summary_tokens = $unit->{tokens};
                log_debug('MessageValidator', "Preserving thread_summary ($summary_tokens tokens)");
            } else {
                push @gap_units, $unit;
                log_debug('MessageValidator', "Collected gap unit (role=$first_msg->{role}, tokens=$unit->{tokens})");
            }
         }
    }
    
    return ($system_msg, $first_user_unit, $start_unit, $system_tokens, $first_user_tokens,
            $summary_unit, $summary_tokens, \@gap_units);
}

sub _compress_dropped {
    my ($dropped_units, $first_user_unit, $debug, $previous_summary) = @_;
    
    return undef unless $dropped_units && @$dropped_units;
    
    my @dropped_messages;
    for my $unit (@$dropped_units) {
        push @dropped_messages, @{$unit->{messages}};
    }
    
    log_debug('MessageValidator', "Compressing " . scalar(@dropped_messages) . " dropped messages");
    
    my $compressed;
    eval {
        require CLIO::Memory::YaRN;
        my $yarn = CLIO::Memory::YaRN->new(debug => $debug);
        
        my $original_task = '';
        if ($first_user_unit && @{$first_user_unit->{messages}}) {
            $original_task = $first_user_unit->{messages}[0]{content} || '';
        }
        
        $compressed = $yarn->compress_messages(\@dropped_messages,
            original_task    => $original_task,
            previous_summary => $previous_summary,
        );
        
        log_debug('MessageValidator', "Compression successful: " . scalar(@dropped_messages) . 
            " messages -> " . ($compressed->{_metadata}{compressed_tokens} || 0) . " tokens");
    };
    if ($@) {
        log_warning('MessageValidator', "Compression failed: $@");
        return undef;
    }
    
    return $compressed;
}

1;

__END__

=head1 AUTHOR

CLIO Project - Extracted from APIManager.pm

=cut
