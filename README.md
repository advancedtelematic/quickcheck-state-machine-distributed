## quickcheck-state-machine-distributed

[![Hackage](https://img.shields.io/hackage/v/quickcheck-state-machine-distributed.svg)](https://hackage.haskell.org/package/quickcheck-state-machine-distributed)
[![Stackage Nightly](http://stackage.org/package/quickcheck-state-machine-distributed/badge/nightly)](http://stackage.org/nightly/package/quickcheck-state-machine-distributed)
[![Stackage LTS](http://stackage.org/package/quickcheck-state-machine-distributed/badge/lts)](http://stackage.org/lts/package/quickcheck-state-machine-distributed)
[![Build Status](https://api.travis-ci.org/advancedtelematic/quickcheck-state-machine-distributed.svg?branch=master)](https://travis-ci.org/advancedtelematic/quickcheck-state-machine-distributed)

`quickcheck-state-machine-distributed` is Haskell library for testing stateful,
possibly distributed, programs. It's based on QuickCheck, but differs from the
[`Test.QuickCheck.Monadic`](https://hackage.haskell.org/package/QuickCheck/docs/Test-QuickCheck-Monadic.html)
approach in that it lets the user specify the correctness by means of a state
machine based model using pre- and post-conditions. The advantage of the state
machine approach is twofold: 1) specifying the correctness of your programs
becomes less adhoc, and 2) you get testing for race conditions for free.

The combination of state machine based model specification and property based
testing first appeared in Erlang's proprietary QuickCheck. The
`quickcheck-state-machine-distributed` library can be seen as an attempt to
provide similar functionality to Haskell's QuickCheck library.

The `quickcheck-state-machine-distributed` library builds upon ideas from the
[`quickcheck-state-machine`](https://github.com/advancedtelematic/quickcheck-state-machine)
sister library. The most significant difference is that the former is based on
the `distributed-process` library, hence the name. A more detailed comparison
follows below.

## Example

See
[`test/TicketDispenser.hs`](https://github.com/advancedtelematic/quickcheck-state-machine-distributed/blob/master/test/TicketDispenser.hs)
for a full example of how to implement and test a ticket dispenser -- think of
one of those machines in the pharmacy which gives you a piece of paper with your
number in line on it.

This example also appears in the *Testing a Database for Race Conditions with
QuickCheck* and *Testing the Hard Stuff and Staying Sane*
[[PDF](http://publications.lib.chalmers.se/records/fulltext/232550/local_232550.pdf),
[video](https://www.youtube.com/watch?v=zi0rHwfiX1Q)] papers.

## `quickcheck-state-machine-distributed` vs `quickcheck-state-machine`

Apart from the already mentioned difference that `-distributed` is based on
`distributed-process`es, it's also different in that it:

* Decouples requests from responses (opening up the possibility for testing
  asynchronous interfaces);

* Takes a more lightweight approach; no GADTs, no references (which hopefully
  makes the library easier to understand and use).

## Contributing

The `quickcheck-state-machine-distributed` library is still very experimental.

We would like to encourage users to try it out, and join the discussion of how
we can improve it on the issue tracker!

## See also

The README of the sister library
[`quickcheck-state-machine`](https://github.com/advancedtelematic/quickcheck-state-machine#readme)
library contains many links and examples that could be useful for a better
understanding of this library and the underlying principles.

## License

BSD-style (see the file LICENSE).
