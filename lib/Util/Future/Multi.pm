
=head1 NAME

Util::Future::Multi - Combinator that completes multiple futures together

=cut

package Util::Future::Multi;

use strict;
use warnings;
use base qw(Util::Future::Combinator);
use Carp;

sub inject {
    my ($class, $futures) = @_;

    my $self = bless {}, $class;

    my $futures_satisfied = 0;

    if (ref($futures) eq 'HASH') {
        my $total_futures = scalar(keys(%$futures));
        my $ret = {};

        foreach my $k (keys %$futures) {
            my $future = $futures->{$k};
            $future->add_on_satisfy_callback(sub {
                my ($result) = @_;
                $ret->{$k} = $result;
                if ((++$futures_satisfied) == $total_futures) {
                    # We're satisfied!
                    $self->satisfy($ret);
                }
            });
        }
    }
    elsif (ref($futures) eq 'ARRAY') {
        my $total_futures = scalar(@$futures);
        my $ret = [];

        # Pre-grow the list to the size we know it'll ultimately be
        # to avoid it getting resized a bunch during processing.
        $ret->[$total_futures - 1] = undef;

        my $idx = 0;
        foreach my $future (@$futures) {
            my $inner_idx = $idx; # So we get a different value for each created closure
            $future->add_on_satisfy_callback(sub {
                my ($result) = @_;
                $ret->[$inner_idx] = $result;
                if ((++$futures_satisfied) == $total_futures) {
                    # We're satisfied!
                    $self->satisfy($ret);
                }
            });
            $idx++;
        }
    }

    return $self->SUPER::inject();
}

1;

