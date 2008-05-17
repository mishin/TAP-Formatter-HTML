=head1 NAME

TAP::Formatter::HTML - Harness output delegate for html output

=head1 SYNOPSIS

 use TAP::Harness;
 my $harness = TAP::Harness->new({ formatter_class => 'TAP::Formatter::HTML' });

 # if you want stderr too:
 my $harness = TAP::Harness->new({ formatter_class => 'TAP::Formatter::HTML',
                                   merge => 1 });

=cut

package TAP::Formatter::HTML;

use strict;
use warnings;

use File::Temp qw( tempfile tempdir );
use File::Spec::Functions qw( catdir );

use Template;
#use Template::Plugin::Cycle;

use base qw( TAP::Base );
use accessors qw( verbosity tests session_class sessions template template_file css_uri js_uri );

use constant default_session_class => 'TAP::Formatter::HTML::Session';

our $VERSION = '0.01';

# DEBUG:
use Data::Dumper 'Dumper';

sub _initialize {
    my ($self, $args) = @_;

    $args ||= {};
    $self->SUPER::_initialize($args);
    $self->verbosity( 0 )
         ->session_class( $self->default_session_class )
         ->template( $self->create_template_processor )
         ->template_file( 'test-results.tt2' );

    return $self;
}

sub create_template_processor {
    my ($self) = @_;
    return Template->new(
			 COMPILE_DIR  => catdir( tempdir(), "TAP-Formatter-HTML-$$" ),
			 COMPILE_EXT  => '.ttc',
			 INCLUDE_PATH => catdir(qw( t data )), # DEBUG
			 EVAL_PERL    => 1, # DEBUG
			);
}

sub verbose      { shift->verbosity >=  1 }
sub quiet        { shift->verbosity <= -1 }
sub really_quiet { shift->verbosity <= -2 }
sub silent       { shift->verbosity <= -3 }

# Called by Test::Harness before any test output is generated.
sub prepare {
    my ($self, @tests) = @_;
    # warn ref($self) . "->prepare called with args:\n" . Dumper( \@tests );
    $self->log( 'running ', scalar @tests, ' tests' );
    $self->sessions([])->tests( [@tests] );
}

# Called to create a new test session. A test session looks like this:
#
#    my $session = $formatter->open_test( $test, $parser );
#    while ( defined( my $result = $parser->next ) ) {
#        $session->result($result);
#        exit 1 if $result->is_bailout;
#    }
#    $session->close_test;
sub open_test {
    my ($self, $test, $parser) = @_;
    #warn ref($self) . "->open_test called with args: " . Dumper( [$test, $parser] );
    my $session = $self->session_class->new({ test => $test, parser => $parser });
    push @{ $self->sessions }, $session;
    return $session;
}

#  $harness->summary( $aggregate );
#
# C<summary> prints the summary report after all tests are run.  The argument is
# an aggregate.
sub summary {
    my ($self, $aggregate) = @_;
    #warn ref($self) . "->summary called with args: " . Dumper( [$aggregate] );

    # farmed out to make sub-classing easy:
    my $report = $self->prepare_report( $aggregate );
    my $html   = $self->generate_report( $report );

    return $html;
}

sub generate_report {
    my ($self, $r) = @_;
    return $self->template->process( $self->template_file, { report => $r } )
      || die $self->template->error;
}

sub prepare_report {
    my ($self, $a) = @_;

    my $r = {
	     tests => [],
	     start_time => '?',
	     end_time => '?',
	     elapsed_time => $a->elapsed_timestr,
	    };

    $r->{css_uri} = $self->css_uri;
    $r->{js_uri}  = $self->js_uri;

    # add aggregate test info:
    for my $key (qw(
		    total
		    has_errors
		    has_problems
		    failed
		    parse_errors
		    passed
		    skipped
		    todo
		    todo_passed
		    wait
		    exit
		   )) {
	$r->{$key} = $a->$key;
    }

    # do some other handy calcs:
    if ($r->{total}) {
	$r->{percent_passed} = sprintf('%.1f', $r->{passed} / $r->{total} * 100);
    } else {
	$r->{percent_passed} = 0;
    }

    # TODO: coverage?

    # add test results:
    my $total_time = 0;
    foreach my $s (@{ $self->sessions }) {
	my $sr = $s->as_report;
	push @{$r->{tests}}, $sr;
	$total_time += $sr->{elapsed_time} || 0;
    }
    $r->{total_time} = $total_time;

    # this is close enough:
    $r->{num_files} = scalar @{ $self->sessions };

    return $r;
}

sub log {
    my ($self, @args) = @_;
    # poor man's logger, but less deps is great!
    print STDERR '# ', @args, "\n";
}


1;

package TAP::Formatter::HTML::Session;

use strict;
use warnings;

use base qw( TAP::Base );
use accessors qw( test parser results closed );

# DEBUG:
use Data::Dumper 'Dumper';

sub _initialize {
    my ($self, $args) = @_;

    $args ||= {};
    $self->SUPER::_initialize($args);

    $self->results([])->closed(0);
    foreach my $arg (qw( test parser )) {
	$self->$arg($args->{$arg}) if defined $args->{$arg};
    }

    $self->log( $self->test, ':' );

    return $self;
}

# Called by TAP::?? to create a result after a session is opened
sub result {
    my ($self, $result) = @_;
    #warn ref($self) . "->result called with args: " . Dumper( $result );
    $self->log( $result->as_string );

    # set this to avoid the hassle of recalculating it in the template:
    if ($result->is_test) {
	$result->{test_status}  = $result->has_todo ? 'todo-' : '';
	$result->{test_status} .= $result->is_actual_ok ? 'ok' : 'not-ok';
    }

    push @{ $self->results }, $result;
    return;
}

# Called by TAP::?? to indicate there are no more test results coming
sub close_test {
    my ($self, @args) = @_;
    # warn ref($self) . "->close_test called with args: " . Dumper( [@args] );
    #print STDERR 'end of: ', $self->test, "\n\n";
    $self->closed(1);
    return;
}

sub as_report {
    my ($self) = @_;
    my $p = $self->parser;
    my $r = {
	    test => $self->test,
	    results => $self->results,
	   };

    # add parser info:
    for my $key (qw(
		    tests_planned
		    tests_run
		    start_time
		    end_time
		    skip_all
		    has_problems
		    failed
		    passed
		    wait
		    exit
		   )) {
	$r->{$key} = $p->$key;
    }

    $r->{num_parse_errors} = $p->parse_errors;
    $r->{parse_errors} = [ $p->parse_errors ];
    $r->{passed_tests} = [ $p->passed ];
    $r->{failed_tests} = [ $p->failed ];

    # do some other handy calcs:
    $r->{test_status} = $r->{has_problems} ? 'not-ok' : 'ok';
    $r->{elapsed_time} = $r->{end_time} - $r->{start_time};
    if ($r->{tests_planned}) {
	my $p = $r->{percent_passed} = sprintf('%.1f', $r->{passed} / $r->{tests_planned} * 100);
	if ($p != 100) {
	    # nb: this also catches more tests passed than planned
	    my $s;
	    if ($p < 25)    { $s = 'very-high' }
	    elsif ($p < 50) { $s = 'high' }
	    elsif ($p < 75) { $s = 'med' }
	    elsif ($p < 95) { $s = 'low' }
	    else            { $s = 'very-low' }
	    $r->{severity} = $s;
	}
    } elsif ($r->{skip_all}) {
	$r->{percent_passed} = '';
    } else {
	$r->{percent_passed} = 0;
	$r->{severity} = 'very-high';
    }

    if ($r->{num_parse_errors}) {
	$r->{severity} = 'very-high';
    }

    if ($r->{has_problems}) {
	$r->{severity} ||= 'high';
    }

    return $r;
}

sub log {
    my ($self, @args) = @_;
    # poor man's logger, but less deps is great!
    print STDERR '# ', @args, "\n";
}


1;


__END__

=head1 DESCRIPTION

This provides html orientated output formatting for TAP::Harness.

=cut

=head1 METHODS

not yet documented...

=head1 AUTHOR

Steve Purkis <spurkis@cpan.org>

=head1 COPYRIGHT

Copyright (c) 2008 S Purkis Consulting Ltd.  All rights reserved.

This module is released under the same terms as Perl itself.

=cut

