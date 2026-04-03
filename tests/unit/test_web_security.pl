#!/usr/bin/env perl
# Test suite for WebOperations URL security checks

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

# We need to test the internal _check_url_security method
# Since it requires a context object, we'll create mock contexts

package MockConfig;
sub new {
    my ($class, %opts) = @_;
    return bless \%opts, $class;
}
sub get {
    my ($self, $key) = @_;
    return $self->{$key};
}

package main;

use CLIO::Tools::WebOperations;

my $pass = 0;
my $fail = 0;
my $total = 0;

sub ok {
    my ($test, $description) = @_;
    $total++;
    if ($test) {
        $pass++;
        print "  ok $total - $description\n";
    } else {
        $fail++;
        print "  NOT ok $total - $description\n";
    }
}

print "=== WebOperations URL Security Tests ===\n\n";

my $web = CLIO::Tools::WebOperations->new();

# --- Standard mode (no special flags) ---
print "--- Standard mode ---\n";

{
    my $ctx = { config => MockConfig->new(security_level => 'standard') };

    # Normal URLs should pass
    my $r = $web->_check_url_security('https://example.com', $ctx);
    ok(!$r->{blocked} && !$r->{requires_confirmation}, "normal URL passes");

    my $r2 = $web->_check_url_security('https://docs.perl.org/perlfunc', $ctx);
    ok(!$r2->{blocked} && !$r2->{requires_confirmation}, "documentation URL passes");
}

# --- Sandbox mode ---
print "\n--- Sandbox mode ---\n";

{
    my $ctx = { config => MockConfig->new(sandbox => 1, security_level => 'standard') };

    my $r = $web->_check_url_security('https://example.com', $ctx);
    ok($r->{blocked}, "sandbox blocks all web ops");
}

# --- Suspicious URLs ---
print "\n--- Suspicious URL detection ---\n";

{
    my $ctx = { config => MockConfig->new(security_level => 'standard') };

    # Long query string (potential exfiltration)
    my $long_data = 'A' x 600;
    my $r = $web->_check_url_security("https://evil.com/collect?data=$long_data", $ctx);
    ok($r->{requires_confirmation}, "long query string flagged");

    # Base64-like content
    my $b64 = 'SGVsbG8gV29ybGQgdGhpcyBpcyBhIHRlc3Qgb2YgYmFzZTY0IGVuY29kaW5nIHRoYXQgaXMgbG9uZyBlbm91Z2ggdG8gdHJpZ2dlcg==';
    my $r2 = $web->_check_url_security("https://evil.com/collect?payload=$b64", $ctx);
    ok($r2->{requires_confirmation}, "base64 content in params flagged");

    # Localhost / internal network (SSRF)
    my $r3 = $web->_check_url_security('http://localhost:8080/admin', $ctx);
    ok($r3->{requires_confirmation}, "localhost URL flagged");

    my $r4 = $web->_check_url_security('http://192.168.1.1/config', $ctx);
    ok($r4->{requires_confirmation}, "private network URL flagged");

    my $r5 = $web->_check_url_security('http://10.0.0.1/internal', $ctx);
    ok($r5->{requires_confirmation}, "10.x network URL flagged");

    my $r6 = $web->_check_url_security('http://127.0.0.1:3000/api', $ctx);
    ok($r6->{requires_confirmation}, "127.0.0.1 URL flagged");

    # Non-HTTP schemes
    my $r7 = $web->_check_url_security('file:///etc/passwd', $ctx);
    ok($r7->{requires_confirmation}, "file:// scheme flagged");

    my $r8 = $web->_check_url_security('ftp://ftp.example.com/secret.tar', $ctx);
    ok($r8->{requires_confirmation}, "ftp:// scheme flagged");
}

# --- Strict mode ---
print "\n--- Strict security mode ---\n";

{
    my $ctx = { config => MockConfig->new(security_level => 'strict') };

    # Even normal URLs require confirmation in strict mode
    my $r = $web->_check_url_security('https://example.com', $ctx);
    ok($r->{requires_confirmation}, "strict: normal URL requires confirmation");
    ok(!$r->{blocked}, "strict: normal URL not blocked");
}

# --- Relaxed mode ---
print "\n--- Relaxed security mode ---\n";

{
    my $ctx = { config => MockConfig->new(security_level => 'relaxed') };

    # Normal URLs pass in relaxed mode
    my $r = $web->_check_url_security('https://example.com', $ctx);
    ok(!$r->{blocked} && !$r->{requires_confirmation}, "relaxed: normal URL passes");

    # But suspicious URLs still flagged
    my $long_data = 'A' x 600;
    my $r2 = $web->_check_url_security("https://evil.com/collect?data=$long_data", $ctx);
    ok($r2->{requires_confirmation}, "relaxed: suspicious URL still flagged");
}

# --- Summary ---
print "\n=== Results: $pass/$total passed";
if ($fail > 0) {
    print " ($fail FAILED)";
}
print " ===\n";

exit($fail > 0 ? 1 : 0);
