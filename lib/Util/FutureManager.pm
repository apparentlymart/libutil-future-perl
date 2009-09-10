
=head1 NAME

Util::FutureManager - Manager of queues of futures

=cut

package Util::FutureManager;

use strict;
use warnings;
use Scalar::Util qw(blessed);

### CONFIGURATION
# This stuff is supposed to be set on application startup.

# Where a caller has requested that a particular future class
# be loaded before another they end up getting weights
# in here which we use to decide which order to run
# batches in. Otherwise, they just run in an undefined order.
our %Class_Weights = ();

### GLOBAL STATE
# This stuff is generally global, but a with_local_future_queue
# block localizes this state to temporarily create a separate
# context.

# The items that still need to be loaded, if any.
# Structure is future_class => batching_key => instance_key => future
our %Queue = ();

# We keep the queue size as an integer so that we
# can quickly determine if there's anything left to
# process
our $Queue_Size = 0;

### STATE DURING LOADING
# These variables get localized during a load operation
# to retain state that is global during that operation.

# Called when $class->register_statisfaction is called
# so that the currently-running batch loop can update
# its lexical state.
our $Satisfaction_Callback = sub {};

# Called when a new future is injected so that the
# currently-running batch loop can update its lexical
# state.
our $Injection_Callback = sub {};

### STATE DURING satisfy_futures
# These are localized for the whole of satisfy_futures

# This retains references to all future objects that
# have been satisfied so that later instances of
# the same future can return immediately without
# a load.
our %Satisfied_Cache = ();

# Need to predeclare this so code below can see the prototype
sub with_profiler(&@);

### CLASS METHODS

# Public Interface

sub satisfy_futures {
    my ($class) = @_;

    # Fast Path
    return unless $Queue_Size > 0;

    # Where we keep loaded objects so we don't load
    # the same things multiple times.
    local %Satisfied_Cache = ();

    my $future_classes = $class->future_classes_in_queue;

    while ($Queue_Size > 0) {
        my $satisfied_this_iteration = 0;
        my $satisfied_this_load = 0;

        local $Satisfaction_Callback = sub {
            $satisfied_this_iteration++;
            $satisfied_this_load++;
        };

        foreach my $handler_class (@$future_classes) {
            foreach my $batching_key (keys %{$Queue{$handler_class}}) {
                my $futures = $Queue{$handler_class}{$batching_key};

                my $expected_to_satisfy = scalar(keys(%$futures)) + 0;
                next unless $expected_to_satisfy > 0;

                $satisfied_this_load = 0;

                Util::FutureManager::with_profiler {
                    # Actually satisfy all of the futures
                    $handler_class->satisfy_multi($futures, $batching_key);
                } $handler_class, $batching_key, $expected_to_satisfy;

                if ($satisfied_this_load != $expected_to_satisfy) {
                    die "$handler_class $batching_key batch expected to satisfy $expected_to_satisfy but actually satisfied $satisfied_this_load";
                }
            }
        }

        die "Did an iteration without satisfying anything" unless $satisfied_this_iteration > 0;
    }

    return undef;
}

sub future_classes_in_queue {
    my ($class) = @_;

    return [ sort { $Class_Weights{$a} <=> $Class_Weights{$b} } keys %Queue ];
}

sub queue_size {
    return $Queue_Size;
}

sub set_preferred_load_order {
    my ($class, $handler_class_1, $handler_class_2) = @_;

    my $first_weight = $Class_Weights{$handler_class_1};
    $first_weight = $Class_Weights{$handler_class_1} = 0 unless defined($first_weight);

    my $second_weight = $Class_Weights{$handler_class_2};
    $Class_Weights{$handler_class_2} = $first_weight + 1 unless defined($second_weight) && $second_weight > $first_weight;

    return undef;
}

# Internal Interface for Util::Future to call into

sub ensure_future_in_queue {
    my ($class, $future) = @_;

    my $handler_class = $future->handler_class;
    my $batching_key = $future->batching_key;
    my $instance_key = $future->instance_key;

    # Do we already have a satisfied future in our cache?
    if (my $satisfied = $Satisfied_Cache{$handler_class}{$batching_key}{$instance_key}) {
        return $satisfied;
    }

    # If we've already got this future in the queue,
    # we return the one we already have so that
    # all callers end up holding the same instance
    # as long as the futures have their constructors
    # written correctly.
    if (my $existing = $Queue{$handler_class}{$batching_key}{$instance_key}) {
        return $existing;
    }
    else {
        $Queue_Size++;
        $Injection_Callback->($future);
        return $Queue{$handler_class}{$batching_key}{$instance_key} = $future;
    }
}

sub register_satisfaction {
    my ($class, $future) = @_;

    my $handler_class = $future->handler_class;
    my $batching_key = $future->batching_key;
    my $instance_key = $future->instance_key;
    my $old_future = delete($Queue{$handler_class}{$batching_key}{$instance_key});
    return unless defined($old_future); # Already satisfied?

    $Satisfied_Cache{$handler_class}{$batching_key}{$instance_key} = $future;
    $Queue_Size--;
    $Satisfaction_Callback->($future);
}

# Debugging Interface

my $profiler = sub { $_[0]->() };

sub set_profiler {
    my ($class, $code) = @_;

    $profiler = $code;
    return undef;
}

### PACKAGE FUNCTIONS

sub with_local_future_queue(&) {
    my ($code) = @_;

    local %Queue = ();
    local $Queue_Size = 0;
    local %Class_Weights = ();
    $code->();
}

### INTERNAL UTILITY FUNCTIONS

sub with_profiler(&@) {
    $profiler->(@_);
}

1;

=head1 METHODS

=head2 $class->satisfy_futures()

Process all queued futures and return once the queue is
exhausted and all futures and their dependencies are
satisfied.

=head2 $class->queue_size

Returns the total number of items in the queue.

=head2 $class->set_preferred_load_order($class1, $class2)

Call this at load time (i.e. before calling C<satisfy_futures>)
to specify that during satisfaction futures of class C<$class1>
should be processed before futures of class C<$class2>.

This can be used in situations where one kind of future
must always be processed before another. The canonical example
of this is if your application has data partitioned by user.
In order to load partitioned data, you first need to lookup
which partition a given user is on.

In principle, it would be better to accomplish this via a
L<Util::Future::Sequence> where the first future is to lookup
the partition, but many systems aren't really architected
to have this as a distinct step but rather do it as a
side-effect of their data load calls, so this method
exists to throw them a bone until they can refactor to
break out the partition lookup to be a future of its own.

=head1 DEBUGGING/ANALYSIS METHODS

During development it is important to verify that your futures
are being delivered in the way you expect, and that bugs aren't
causing dependencies to be handled in a sub-optimal way.
This class provides a hook through which you can optionally
track each batch-load to see what individual load calls are
being made.

=head2 $class->set_profiler($code)

Provide a code ref that will be called when each batch-load
happens. It is passed the following parameters:

    ($code, $future_class, $batching_key, $count)

Your implementation must start any timer it wishes to start,
then run C<$code-E<gt>()> (with no arguments) and, once
it returns, do any logging you want to do.

C<$future_class> and C<$batching_key> are the identifiers
for this particular batch, while C<$count> is the number
of distinct futures being handled in this batch.

=head1 FUNCTIONS

=head2 Util::FutureManager::with_local_feature_queue { ... }

Runs the provided block in a context with a localized feature queue.

This is useful if you want to do a small set of segregated loads
without processing the full queue, but in the common case you'll
want to do all of your loading in one place for maximum batching
efficiency.

This also allows you to run a future loop within the loader
of a future, should you need to do that for some bizarre reason.

