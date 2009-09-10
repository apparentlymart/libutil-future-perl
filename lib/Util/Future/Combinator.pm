
=head1 NAME

Util::Future::Combinator - Abstract base class for futures that are really just containers for other futures

=cut

package Util::Future::Combinator;

use strict;
use warnings;
use base qw(Util::Future);
use Carp;

# Inject doesn't actually inject.
sub inject {
    return $_[0];
}

# This overridden version omits the call into FutureManager, since
# FutureManager doesn't actually know anything about combinator futures.
sub satisfy {
    my ($self, $result) = @_;

    croak "Can't re-satisfy $self" if exists $self->{Util::Future::RESULT()};
    $self->{Util::Future::RESULT()} = $result;

    $self->run_on_satisfy_callbacks();
}

sub handler_class {
    die "There is no handler_class for combinator future $_[0]";
}
sub batching_key {
    die "There is no batching_key for combinator future $_[0]";
}
sub instance_key {
    die "There is no instance_key for combinator future $_[0]";
}

sub satisfy_multi {
    die "Can't satisfy_multi on a combinator future";
}

1;

=head1 DESCRIPTION

While normal futures do some action and then get satisfied, "combinator"
futures instead act as a container for one or more other futures
and are considered satisfied once all of the contained futures
are satisfied.

Combinator futures never actually go into the future queue, but they'll
inject their contained futures into the queue as required and then
produce some kind of summary result based on the real futures they
ran.

This is an abstract base class. Inherit from this class if you want
to make a combinator future.

Since combinator futures are never enqueued, you do not need to
provide implementations of C<satisfy_multi>, C<handler_class>,
C<batching_key> or C<instance_key>. Instead, your injector
method(s) will inject the contained futures and then attach
on-satisfy callbacks to them, ultimately calling C<$self-E<gt>satisfy>
once the combinator is considered "complete".

=head1 INCLUDED COMBINATORS

The Util::Future distribution includes C<Util::Future::Sequence>
and C<Util::Future::Multi>, which are both combinator futures.

