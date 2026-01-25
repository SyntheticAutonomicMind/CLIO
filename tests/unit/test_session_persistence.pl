#!/usr/bin/env perl
# Test to verify session is saved on API errors and normal exit

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use Test::More tests => 4;
use File::Temp qw(tempdir);
use File::Spec;

# Test 1: Verify clio script has session save after run()
{
    my $clio_script = "$RealBin/../../clio";
    ok(-f $clio_script, "clio script exists");
    
    open my $fh, '<', $clio_script or die "Cannot read clio: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    # Check for session save after $ui->run()
    like($content, qr/\$ui->run\(\);.*?\$session->save\(\);/s, 
        "clio script saves session after interactive run()");
}

# Test 2: Verify Chat.pm saves session on errors
{
    my $chat_pm = "$RealBin/../../lib/CLIO/UI/Chat.pm";
    ok(-f $chat_pm, "Chat.pm exists");
    
    open my $fh, '<', $chat_pm or die "Cannot read Chat.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    # Check for session save in error handling block
    like($content, qr/Store error in session.*?\$self->\{session\}->save\(\);/s,
        "Chat.pm saves session immediately after errors");
}

done_testing();
