
=head1 NAME

Util::Future::Sequence - Chain together multiple futures to produce a result

=cut

package Util::Future::Sequence;

use strict;
use warnings;
use base qw(Util::Future::Combinator);
use Carp;

sub inject {
    my ($class, $seed_future, @funcs) = @_;

    my $self = bless {}, $class;

    my $mangle_future;
    $mangle_future = sub {
        my ($future) = @_;

        $future->add_on_satisfy_callback(sub {
            my ($result) = @_;

            my $func = shift @funcs or croak "No progression function provided to accept result of future $future";
            my $next = $func->($result);

            if (UNIVERSAL::isa($next, 'Util::Future')) {
                $mangle_future->($next);
            }
            else {
                $self->satisfy($next);
            }
        });
    };

    $mangle_future->($seed_future);

    return $self->SUPER::inject();
}

1;

=head1 SYNOPSIS

    my $load_user = Util::Future::Sequence->inject(
        Some::App::Future::GetUserId->inject_for_user_name('frank'),
        sub {
            my $user_id = shift;
            return Some::App::Future::GetUser->inject_for_user_id($user_id),
        },
        sub {
            my $user = shift;
            return $user;
        },
    );

=head1 DESCRIPTION

The intent of this class is to provide the ability to encapsulate a sequence
of separate futures into a single future object, thus allowing the recipient
of the sequence to treat it like any other future.

=head1 USAGE

The basic model of a future sequence is that you provide an already-injected
"seed" future, which will start the sequence, and then one or more progression
functions that take the result from the previous step and return either
another future for the next step or return a final value.

A progression function takes as its first argument the result of the previous
step. If it returns a subclass of C<Util::Future> then an on-satisfy callback
will be attached which will run the next progression function. If it returns
anything else then that value will be considered to be the final value of
the sequence and the sequence future itself will complete: it'll run its
own on-satisfy callbacks and then terminate.

