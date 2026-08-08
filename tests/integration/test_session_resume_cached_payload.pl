#!/usr/bin/env perl
# Integration test for the "reload current state" session resume fast path.
#
# Flow:
#   1. Start a session, ask a question, get an answer
#   2. Verify the session JSON contains last_api_payload + last_api_metadata
#   3. Resume the session, ask a follow-up
#   4. Verify the resumed turn saw the cached payload (debug log line)
#
# Run with: perl -I./lib tests/integration/test_session_resume_cached_payload.pl

use strict;
use warnings;
use lib 'lib';
use CLIO::Util::JSON qw(decode_json);
use File::Spec;

print "Testing cached-payload session resume...\n\n";

# Helper: run clio with a single input and capture session ID + debug log.
sub run_clio {
    my (%args) = @_;
    my $input    = $args{input}    // die "input required";
    my $resume   = $args{resume};                 # optional session id
    my $extra    = $args{extra}    // '';

    my @cmd = ('./clio', '--debug', '--input', $input, '--exit');
    push @cmd, '--resume', $resume if $resume;
    push @cmd, split /\s+/, $extra if $extra;

    my $output = `@cmd 2>&1`;
    return $output;
}

sub extract_session_id {
    my ($output) = @_;
    my ($sid) = $output =~ /Using\s+session:\s+([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})/i;
    return $sid;
}

# ============================================================================
# TEST 1: First turn writes last_api_payload to session JSON
# ============================================================================
print "[TEST 1] First turn writes last_api_payload + last_api_metadata\n";

my $out1 = run_clio(input => 'What is 2+2?');
my $sid1 = extract_session_id($out1);
die "FAIL: Could not extract session ID from first run\n" unless $sid1;
print "  [OK] Session created: $sid1\n";

# Locate the session JSON
my $session_file = ".clio/sessions/$sid1.json";
die "FAIL: Session file missing: $session_file\n" unless -f $session_file;

my $json_text = do { local $/; open my $fh, '<', $session_file or die $!; <$fh> };
my $data = decode_json($json_text);

die "FAIL: last_api_payload missing from session JSON\n"
    unless exists $data->{last_api_payload} && ref($data->{last_api_payload}) eq 'ARRAY';
die "FAIL: last_api_payload is empty\n" unless @{$data->{last_api_payload}};
print "  [OK] last_api_payload present, " . scalar(@{$data->{last_api_payload}}) . " messages\n";

die "FAIL: last_api_metadata missing\n" unless exists $data->{last_api_metadata};
die "FAIL: last_api_metadata.saved_at missing\n" unless $data->{last_api_metadata}{saved_at};
die "FAIL: last_api_metadata.provider missing\n" unless $data->{last_api_metadata}{provider};
die "FAIL: last_api_metadata.context_window missing\n" unless $data->{last_api_metadata}{context_window};
print "  [OK] last_api_metadata present (provider=" . ($data->{last_api_metadata}{provider} // 'undef') .
      ", ctx=" . ($data->{last_api_metadata}{context_window} // 0) . ")\n";

# ============================================================================
# TEST 2: Resume logs the fast-path activation
# ============================================================================
print "\n[TEST 2] Resuming takes the fast path (debug log present)\n";

my $out2 = run_clio(input => 'Now what is 3+3?', resume => $sid1);

my $used_fast_path = ($out2 =~ /Resume (?:using cached payload|fast path)/)
                  || ($out2 =~ /Resume payload skipped/);
die "FAIL: No resume debug line found in second run output:\n$out2\n"
    unless $used_fast_path;
print "  [OK] Resume fast-path log line detected\n";

# ============================================================================
# TEST 3: Session after resume still has the cached payload (not lost)
# ============================================================================
print "\n[TEST 3] Session after resume still carries last_api_payload\n";

my $data2 = decode_json(do { local $/; open my $fh, '<', $session_file or die $!; <$fh> });
die "FAIL: last_api_payload empty after resume\n" unless @{$data2->{last_api_payload}};
die "FAIL: last_api_payload shrank unexpectedly after resume\n"
    if @{$data2->{last_api_payload}} < @{$data->{last_api_payload}};
print "  [OK] Payload grew from " . scalar(@{$data->{last_api_payload}}) .
      " to " . scalar(@{$data2->{last_api_payload}}) . " messages\n";

print "\nAll cached-payload resume tests passed.\n";
exit 0;