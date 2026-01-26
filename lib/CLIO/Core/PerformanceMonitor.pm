package CLIO::Core::PerformanceMonitor;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use feature 'say';
use Time::HiRes qw(time);

=head1 NAME

CLIO::Core::PerformanceMonitor - Track API endpoint and model performance

=head1 DESCRIPTION

Monitors API endpoint performance metrics to help select the best endpoint.
Tracks:
- Response times (average, recent)
- Success rates
- Tokens per second
- Total calls

Adapted from collaborait's PerformanceMonitor but simplified for single-threaded use.

=cut

# Global performance data (singleton pattern)
my $ENDPOINT_METRICS = {};
my $MODEL_METRICS = {};
my $CALL_HISTORY = [];
my $MAX_HISTORY = 100;  # Keep last 100 calls for recent metrics

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} || 0,
    };
    
    return bless $self, $class;
}

=head2 record_api_call

Record metrics from an API call.

Arguments:
- $endpoint: API endpoint URL or identifier
- $model: Model name
- $params: Hash with start_time, end_time, success, tokens_in, tokens_out, error

Returns: None (updates internal metrics)

=cut

sub record_api_call {
    my ($self, $endpoint, $model, $params) = @_;
    
    my $start_time = $params->{start_time};
    my $end_time = $params->{end_time} || time();
    my $response_time = $end_time - $start_time;
    my $success = $params->{success} // 0;
    my $tokens_in = $params->{tokens_in} || 0;
    my $tokens_out = $params->{tokens_out} || 0;
    my $total_tokens = $tokens_in + $tokens_out;
    my $error = $params->{error};
    
    print STDERR "[DEBUG][PerformanceMonitor] Recording call: endpoint=$endpoint model=$model time=${response_time}s success=$success\n" if should_log('DEBUG');
    
    # Record endpoint metrics
    $self->_update_endpoint_metrics($endpoint, $response_time, $success, $total_tokens, $tokens_out);
    
    # Record model metrics
    $self->_update_model_metrics($model, $response_time, $success, $total_tokens, $tokens_out);
    
    # Add to call history
    push @$CALL_HISTORY, {
        timestamp => time(),
        endpoint => $endpoint,
        model => $model,
        response_time => $response_time,
        success => $success,
        tokens_in => $tokens_in,
        tokens_out => $tokens_out,
        total_tokens => $total_tokens,
        error => $error,
    };
    
    # Trim history if too long
    if (@$CALL_HISTORY > $MAX_HISTORY) {
        shift @$CALL_HISTORY;
    }
}

=head2 _update_endpoint_metrics

Update metrics for a specific endpoint (internal)

=cut

sub _update_endpoint_metrics {
    my ($self, $endpoint, $response_time, $success, $total_tokens, $tokens_out) = @_;
    
    $ENDPOINT_METRICS->{$endpoint} ||= {
        total_calls => 0,
        successful_calls => 0,
        failed_calls => 0,
        total_response_time => 0,
        total_tokens => 0,
        total_tokens_out => 0,
        response_times => [],
        last_call => 0,
    };
    
    my $stats = $ENDPOINT_METRICS->{$endpoint};
    
    $stats->{total_calls}++;
    $stats->{successful_calls}++ if $success;
    $stats->{failed_calls}++ unless $success;
    $stats->{total_response_time} += $response_time;
    $stats->{total_tokens} += $total_tokens;
    $stats->{total_tokens_out} += $tokens_out;
    $stats->{last_call} = time();
    
    # Track recent response times
    push @{$stats->{response_times}}, $response_time;
    if (@{$stats->{response_times}} > 20) {
        shift @{$stats->{response_times}};
    }
    
    # Calculate derived metrics
    $stats->{avg_response_time} = $stats->{total_response_time} / $stats->{total_calls};
    $stats->{success_rate} = $stats->{successful_calls} / $stats->{total_calls};
    $stats->{avg_tokens_per_call} = $stats->{total_tokens} / $stats->{total_calls};
    $stats->{tokens_per_second} = $total_tokens / $response_time if $response_time > 0;
    
    # Calculate recent average (last 20 calls)
    if (@{$stats->{response_times}} > 0) {
        my $sum = 0;
        $sum += $_ for @{$stats->{response_times}};
        $stats->{recent_avg_response_time} = $sum / scalar(@{$stats->{response_times}});
    }
}

=head2 _update_model_metrics

Update metrics for a specific model (internal)

=cut

sub _update_model_metrics {
    my ($self, $model, $response_time, $success, $total_tokens, $tokens_out) = @_;
    
    $MODEL_METRICS->{$model} ||= {
        total_calls => 0,
        successful_calls => 0,
        failed_calls => 0,
        total_response_time => 0,
        total_tokens => 0,
        total_tokens_out => 0,
        response_times => [],
        last_call => 0,
    };
    
    my $stats = $MODEL_METRICS->{$model};
    
    $stats->{total_calls}++;
    $stats->{successful_calls}++ if $success;
    $stats->{failed_calls}++ unless $success;
    $stats->{total_response_time} += $response_time;
    $stats->{total_tokens} += $total_tokens;
    $stats->{total_tokens_out} += $tokens_out;
    $stats->{last_call} = time();
    
    # Track recent response times
    push @{$stats->{response_times}}, $response_time;
    if (@{$stats->{response_times}} > 20) {
        shift @{$stats->{response_times}};
    }
    
    # Calculate derived metrics
    $stats->{avg_response_time} = $stats->{total_response_time} / $stats->{total_calls};
    $stats->{success_rate} = $stats->{successful_calls} / $stats->{total_calls};
    $stats->{avg_tokens_per_call} = $stats->{total_tokens} / $stats->{total_calls};
    $stats->{tokens_per_second} = $total_tokens / $response_time if $response_time > 0;
    
    # Calculate recent average
    if (@{$stats->{response_times}} > 0) {
        my $sum = 0;
        $sum += $_ for @{$stats->{response_times}};
        $stats->{recent_avg_response_time} = $sum / scalar(@{$stats->{response_times}});
    }
}

=head2 get_endpoint_stats

Get statistics for a specific endpoint or all endpoints

Arguments:
- $endpoint: Optional endpoint identifier (returns all if not provided)

Returns: Hash or hashref of endpoint statistics

=cut

sub get_endpoint_stats {
    my ($self, $endpoint) = @_;
    
    if ($endpoint) {
        return $ENDPOINT_METRICS->{$endpoint};
    }
    
    return $ENDPOINT_METRICS;
}

=head2 get_model_stats

Get statistics for a specific model or all models

Arguments:
- $model: Optional model name (returns all if not provided)

Returns: Hash or hashref of model statistics

=cut

sub get_model_stats {
    my ($self, $model) = @_;
    
    if ($model) {
        return $MODEL_METRICS->{$model};
    }
    
    return $MODEL_METRICS;
}

=head2 get_best_endpoint

Get the best performing endpoint based on recent metrics

Returns: Endpoint identifier or undef

=cut

sub get_best_endpoint {
    my ($self) = @_;
    
    return undef unless keys %$ENDPOINT_METRICS;
    
    # Score endpoints by: success_rate * tokens_per_second / recent_avg_response_time
    my $best_endpoint = undef;
    my $best_score = 0;
    
    for my $endpoint (keys %$ENDPOINT_METRICS) {
        my $stats = $ENDPOINT_METRICS->{$endpoint};
        
        # Skip if no successful calls
        next unless $stats->{successful_calls} > 0;
        
        my $success_rate = $stats->{success_rate};
        my $tokens_per_sec = $stats->{tokens_per_second} || 0;
        my $response_time = $stats->{recent_avg_response_time} || $stats->{avg_response_time};
        
        # Avoid division by zero
        next if $response_time == 0;
        
        my $score = $success_rate * $tokens_per_sec / $response_time;
        
        if ($score > $best_score) {
            $best_score = $score;
            $best_endpoint = $endpoint;
        }
    }
    
    return $best_endpoint;
}

=head2 format_stats

Format statistics for display

Arguments:
- $type: 'endpoint' or 'model'

Returns: Formatted string

=cut

sub format_stats {
    my ($self, $type) = @_;
    
    $type ||= 'endpoint';
    
    my $stats = $type eq 'model' ? $MODEL_METRICS : $ENDPOINT_METRICS;
    my $label = $type eq 'model' ? 'Model' : 'Endpoint';
    
    return "No performance data available.\n" unless keys %$stats;
    
    my $output = "\n";
    $output .= "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" . "\n";
    $output .= "$label Performance Statistics\n";
    $output .= "\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501" . "\n\n";
    
    for my $name (sort keys %$stats) {
        my $s = $stats->{$name};
        
        $output .= sprintf("%-40s\n", $name);
        $output .= sprintf("  Calls:          %d (✓ %d, ✗ %d)\n", 
            $s->{total_calls}, $s->{successful_calls}, $s->{failed_calls});
        $output .= sprintf("  Success Rate:   %.1f%%\n", $s->{success_rate} * 100);
        $output .= sprintf("  Avg Response:   %.2fs\n", $s->{avg_response_time});
        $output .= sprintf("  Recent Avg:     %.2fs\n", $s->{recent_avg_response_time} || $s->{avg_response_time});
        $output .= sprintf("  Tokens/sec:     %.1f\n", $s->{tokens_per_second} || 0);
        $output .= sprintf("  Avg Tokens:     %.0f\n", $s->{avg_tokens_per_call});
        $output .= "\n";
    }
    
    return $output;
}

=head2 reset

Reset all performance metrics

=cut

sub reset {
    my ($self) = @_;
    
    $ENDPOINT_METRICS = {};
    $MODEL_METRICS = {};
    $CALL_HISTORY = [];
    
    print STDERR "[DEBUG][PerformanceMonitor] All metrics reset\n" if should_log('DEBUG');
}

1;

__END__

=head1 USAGE

    use CLIO::Core::PerformanceMonitor;
    use Time::HiRes qw(time);
    
    my $monitor = CLIO::Core::PerformanceMonitor->new(debug => 1);
    
    # Record an API call
    my $start = time();
    # ... make API call ...
    my $end = time();
    
    $monitor->record_api_call(
        'https://api.openai.com/v1',
        'gpt-4',
        {
            start_time => $start,
            end_time => $end,
            success => 1,
            tokens_in => 100,
            tokens_out => 200,
        }
    );
    
    # Get statistics
    my $stats = $monitor->get_endpoint_stats();
    print $monitor->format_stats('endpoint');
    
    # Get best endpoint
    my $best = $monitor->get_best_endpoint();

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.
1;
