package CLIO::Core::API::MessageValidator;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(should_log log_debug log_info log_warning);

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
        
        if (should_log('WARNING')) {
            log_warning('MessageValidator', "Model capabilities unavailable for $model");
            log_warning('MessageValidator', "Using fallback token limit: $max_prompt");
        }
    }
    
    # Calculate tool token budget
    my $tool_tokens = _calculate_tool_tokens($tools);
    
    # Safety margins
    my $estimation_margin = int($max_prompt * 0.10);
    my $response_buffer = 8000;
    my $effective_limit = $max_prompt - $tool_tokens - ($estimation_margin + $response_buffer);
    $effective_limit = 1000 if $effective_limit < 1000;
    
    log_debug('MessageValidator', "Token budget: max=$max_prompt, tools=$tool_tokens, effective=$effective_limit");
    
    # Estimate token usage
    my $estimated_tokens = _estimate_tokens($messages, $token_ratio);
    
    if ($estimated_tokens <= $effective_limit) {
        log_debug('MessageValidator', "Token validation: $estimated_tokens / $effective_limit tokens (OK)");
        return validate_tool_message_pairs($messages);
    }
    
    # Exceeds limit - need to truncate
    log_debug('MessageValidator', "Messages exceed token limit: $estimated_tokens > $effective_limit, truncating");
    
    # Group messages into units
    my ($units_ref, $tool_id_map) = _group_into_units($messages);
    my @units = @$units_ref;
    
    log_debug('MessageValidator', "Grouped " . scalar(@$messages) . " messages into " . scalar(@units) . " units");
    
    # Extract system message and first user message
    my ($system_msg, $first_user_unit, $start_unit, $system_tokens, $first_user_tokens) = 
        _extract_preserved_units(\@units);
    
    # Build conversation from newest to oldest
    my @conversation;
    my $current_tokens = $system_tokens + $first_user_tokens;
    my %included_tool_ids;
    my @dropped_units;
    
    my @remaining = @units[$start_unit .. $#units];
    
    for my $unit (reverse @remaining) {
        if ($unit->{is_orphan_tool_result}) {
            log_debug('MessageValidator', "Skipping orphan tool_result unit (tool_id: $unit->{orphan_tool_id})");
            next;
        }
        
        if ($current_tokens + $unit->{tokens} <= $effective_limit) {
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
    my $compressed = _compress_dropped(\@dropped_units, $first_user_unit, $debug);
    
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
    push @truncated, $compressed if $compressed;
    push @truncated, @{$first_user_unit->{messages}} if $first_user_unit;
    push @truncated, @validated;
    
    if (should_log('DEBUG')) {
        my $final_tokens = _estimate_tokens(\@truncated, 2.5);
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
    
    # Collect tool_call IDs
    my %tool_call_ids;
    for (my $i = 0; $i < @$messages; $i++) {
        my $msg = $messages->[$i];
        if ($msg->{role} && $msg->{role} eq 'assistant' && 
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                $tool_call_ids{$tc->{id}} = $i if $tc->{id};
            }
        }
    }
    
    # Collect tool_result IDs
    my %tool_result_ids;
    for (my $i = 0; $i < @$messages; $i++) {
        my $msg = $messages->[$i];
        if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
            $tool_result_ids{$msg->{tool_call_id}} = $i;
        }
    }
    
    # Find orphans
    my %orphaned_call_indices;
    for my $tc_id (keys %tool_call_ids) {
        unless (exists $tool_result_ids{$tc_id}) {
            $orphaned_call_indices{$tool_call_ids{$tc_id}} = 1;
            log_debug('MessageValidator', "Orphaned tool_call: $tc_id at message $tool_call_ids{$tc_id}");
        }
    }
    
    my %orphaned_result_indices;
    for my $tr_id (keys %tool_result_ids) {
        unless (exists $tool_call_ids{$tr_id}) {
            $orphaned_result_indices{$tool_result_ids{$tr_id}} = 1;
            log_debug('MessageValidator', "Orphaned tool_result: $tr_id at message $tool_result_ids{$tr_id}");
        }
    }
    
    # If no orphans, return original
    if (!keys %orphaned_call_indices && !keys %orphaned_result_indices) {
        log_debug('MessageValidator', "Tool message validation: all pairs valid");
        return $messages;
    }
    
    # Rebuild without orphans
    my @validated;
    for (my $i = 0; $i < @$messages; $i++) {
        my $msg = $messages->[$i];
        
        if ($orphaned_result_indices{$i}) {
            log_debug('MessageValidator', "Removing orphaned tool_result at index $i");
            next;
        }
        
        if ($orphaned_call_indices{$i}) {
            push @validated, { role => $msg->{role}, content => $msg->{content} || '' };
            log_debug('MessageValidator', "Stripped tool_calls from assistant at index $i");
            next;
        }
        
        push @validated, $msg;
    }
    
    my $removed = scalar(@$messages) - scalar(@validated);
    log_info('MessageValidator', "Removed/fixed $removed orphaned tool messages") if $removed > 0;
    
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
    my ($messages, $ratio) = @_;
    $ratio ||= 2.5;
    
    my $total = 0;
    for my $msg (@$messages) {
        $total += int(length($msg->{content} || '') / $ratio);
        if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                my $json = eval { require JSON::PP; JSON::PP::encode_json($tc) };
                $total += int(length($json || '') / $ratio);
            }
        }
        $total += 50 if $msg->{role} && $msg->{role} eq 'tool';
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
        my $msg_tokens = int(length($msg->{content} || '') / 2.5);
        my $has_tool_calls = $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY' && @{$msg->{tool_calls}};
        my $is_tool_result = $msg->{tool_call_id} || ($msg->{role} && $msg->{role} eq 'tool');
        
        if ($has_tool_calls) {
            push @units, $current_unit if $current_unit;
            
            $current_unit = { messages => [$msg], tokens => $msg_tokens, tool_call_ids => {} };
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
    
    # Extract system message
    if (@$units && @{$units->[0]{messages}} && $units->[0]{messages}[0]{role} eq 'system') {
        $system_msg = $units->[0]{messages}[0];
        $system_tokens = $units->[0]{tokens};
        $start_unit = 1;
    }
    
    # Extract first user message (importance >= 10.0)
    for my $i ($start_unit .. $#$units) {
        my $unit = $units->[$i];
        next unless $unit && $unit->{messages} && @{$unit->{messages}};
        
        my $first_msg = $unit->{messages}[0];
        if ($first_msg->{role} && $first_msg->{role} eq 'user') {
            if (($first_msg->{_importance} // 0) >= 10.0) {
                $first_user_unit = $unit;
                $first_user_tokens = $unit->{tokens};
                $start_unit = $i + 1;
                log_debug('MessageValidator', "Preserving first user message (importance=" . 
                    ($first_msg->{_importance} // 0) . ", tokens=$first_user_tokens)");
            }
            last;
        }
    }
    
    return ($system_msg, $first_user_unit, $start_unit, $system_tokens, $first_user_tokens);
}

sub _compress_dropped {
    my ($dropped_units, $first_user_unit, $debug) = @_;
    
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
            original_task => $original_task
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
