package CLIO::Core::NaturalLanguage;
use strict;
use warnings;
use CLIO::NLPromptProcessor;

sub new {
    my ($class, %opts) = @_;
    my $self = { debug => $opts{debug} || 0 };
    return bless $self, $class;
}

sub process_natural_language {
    my ($self, $user_input, $context) = @_;
    my $debug = $self->{debug};
    my $result = CLIO::NLPromptProcessor::process_nl_prompt($user_input, $context, $debug, 0);
    # Wrap result in expected structure
    return {
        success => $result->{success} // 1,
        final_response => $result->{final_response} // $result->{response} // '',
        protocols_used => $result->{protocols_used} // [],
        confidence => $result->{confidence} // 1,
        natural_language_result => $result,
    };
}

1;
