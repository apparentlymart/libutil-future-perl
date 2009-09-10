
=head1 NAME

Util::Future - A description of something to load in future

=cut

package Util::Future;

use strict;
use warnings;
use Scalar::Util qw(refaddr blessed);
use Carp;
use Util::FutureManager;

our $VERSION = '0.01';

use constant ON_SATISFY_CALLBACKS => __PACKAGE__.'::on_satisfy_callbacks';
use constant RESULT => __PACKAGE__.'::result';

### METHODS FOR SUBCLASSES TO OVERRIDE

sub handler_class {
    # Default is the class our instance is blessed onto
    return blessed($_[0]);
}

sub batching_key {
    return 'all';
}

sub instance_key {
    # Default is our instance refaddr, which makes each
    # instance completely distinct. This is a safe default,
    # but subclasses really should override this to return
    # a true coalescing key to avoid duplicate lookups.
    return refaddr($_[0]);
}

sub satisfy_multi {
    croak "$_[0] does not provide an implementation of satisfy_multi";
}

### METHODS FOR SUBCLASSES TO CALL

sub satisfy {
    my ($self, $result) = @_;

    croak "Can't re-satisfy $self" if exists $self->{RESULT()};
    $self->{RESULT()} = $result;

    Util::FutureManager->register_satisfaction($self);
    $self->run_on_satisfy_callbacks();
}

sub inject {
    my ($self) = @_;

    return Util::FutureManager->ensure_future_in_queue($self);
}

### PUBLIC INSTANCE METHODS

sub result {
    my ($self) = @_;

    croak("$self is not yet satisfied") unless exists $self->{RESULT()};

    return $self->{RESULT()};
}

sub satisfied {
    return exists($_[0]->{RESULT()}) ? 1 : 0;
}

sub add_on_satisfy_callback {
    my ($self, $cb) = @_;

    croak "Provided callback must be a CODE reference" unless ref($cb) eq 'CODE';

    # If someone tries to add a callback to an already-satisfied future,
    # we just run the callback immediately, since otherwise it's never
    # going to get called.
    if ($self->satisfied) {
        $cb->($self->result);
    }
    else {
        $self->{ON_SATISFY_CALLBACKS()} ||= [];
        push @{$self->{ON_SATISFY_CALLBACKS()}}, $cb;
    }

    return undef;
}

### PRIVATE METHODS

sub run_on_satisfy_callbacks {
    my ($self) = @_;

    my $result = $self->result;
    foreach my $cb (@{$self->{ON_SATISFY_CALLBACKS()}}) {
        $cb->($result);
    }
}

1;

=head1 SYNOPSIS

    package My::App::Future::LoadUser;
    
    use base qw(Util::Future);
    
    sub inject_for_user_id {
        my ($class, $user_id) = @_;
        
        # Object MUST be a blessed HASH ref.
        my $self = bless {}, $class;
        
        $self->{user_id} = $user_id;
        
        # You MUST return what $self->inject returns,
        # not $self directly. (See SUBCLASS API below
        # to find out why.)
        return $self->inject();
    }

=head1 DESCRIPTION

This is an abstract base class for different classes of
'future'. A 'future' is a description of something
you want to load in future, but you don't want to load
right now.

L<Util::FutureManager> can then be used to load
all queued futures in batch, with as few I/O round
trips as possible.

=head1 PUBLIC INSTANCE API

=head2 $future->result

Returns whatever value resulted from executing the
load operation associated with this future, or dies
if the load has not yet taken place.

=head2 $future->add_on_satisfy_callback($cb)

Adds a callback which will be called once this
future's result has been delivered.

This is how combinator futures are implemented.
See L<Util::Future::Combinator> for more information.

=head1 PUBLIC STATIC API

The following utility methods are provided as
shorthands for operations that would normally
require multiple steps.

=head1 SUBCLASS API

=head2 $class->satisfy_multi($futures, $batching_key)

Called by L<Util::FutureManager> to satisfy a bunch of
futures of a given type.

C<$futures> is a HASH ref mapping instance_id to future
instance. All of the futures provided are guaranteed to
have a C<batching_key> matching that in C<$batching_key>.

Any subclass that's ever returned as the C<handler_class>
for a future must override this method.

The implementation of C<satisfy_multi> B<MUST> call
C<$future-E<gt>satisfy($value)> exactly once on every future in the
provided set before returning. You may explicitly satisfy with C<undef> if
there is no useful result to return for a particular
future.

=head2 $future->satisfy($result)

To be called by your C<satisfy_multi> implementation once
you've got a result for a particular future.

This must only be called from a C<satisfy_multi> implementation.
Calling it elsewhere will cause things to get into an
inconsistent state, so don't do that.

=head2 $future->handler_class

Called to determine which class we will invoke C<satisfy_multi>
on to satisfy this class.

The default implementation returns the class onto which C<$future>
is blessed, but subclasses can override this if they wish
to handle several different kinds of futures with a single
base class.

=head2 $future->batching_key

Called to determine which batch this future will be placed
into when loading.

This allows multiple futures of the same type to
actually be satisfied via separate calls to C<satisfy_multi>.
This can be useful, for example, if your handler
loads some data about a bunch of users but your user
data is partitioned into separate data stores and you
can only query one partition at a time: just
set batching_key to be the partition id and you'll
automatically get a separate C<satisfy_multi> call for each
partition.

The default implementation returns the literal string
"all", which causes all futures to get handled together
in a single batch.

Subclasses can override this to return a batch discriminator
if they need to distinguish between different batch
loads of the same type, but the C<batching_key> MUST be
a string or something that can sensibly be compared as a string
since it will be used as a hash key internally.

=head2 $future->instance_key

Called to determine a unique key for this specific operation.
Multiple futures with the same (C<handler_class>, C<batching_key>,
C<instance_key>) tuple will be coalesced together and
handled as a single future.

The default is to return the C<refaddr> of the $future instance,
which effectively makes each future distinct. It is strongly
recommended for subclasses to override this and return a true
identifier for what is being loaded, such as the primary key
of the object if your instance is loading data relating to
a particular object from a data store.

Two futures with the same batching tuple should NEVER exist
concurrently in memory except within the scope of an
injector method as described in the following section.

=head2 Your own injector method(s)

Subclasses must provide one or more class methods to create and
inject new futures of that type. These MUST be of the following
form:

    sub inject_for_user_id {
        my ($class, $user_id) = @_;

        # $self MUST be a blessed HASH ref
        my $self = bless {}, $class;

        $self->{user_id} = $user_id;

        # You MUST return what $self->inject returns
        return $self->inject;
    }

There are two important requirements here.

First, you MUST use a HASH ref as the backing store for your
instances. This is because the base class will write its own
state in there and expects to be able to treat C<$self> as a
hash.

Secondly, you MUST end your injector method with a call
to C<$self->inject> AND return what it returns. DO NOT
return your own C<$self> directly under any circumstances.

This is because internally L<Util::FutureManager> ensures
that no two instances of the same task (identified by
its coalescing tuple as described above) exist, and
so the return value of C<inject> may be a different instance
of the same class that another caller injected earlier.

