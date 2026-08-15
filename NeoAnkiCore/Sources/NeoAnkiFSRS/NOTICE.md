# FSRS reference provenance

This module is a native Swift port of `open-spaced-repetition/fsrs-rs` at
commit `6f5498f8dd1a95c781fcdd4448f28f16dd9e377d` (manifest version 6.6.2).

The upstream source is licensed under BSD-3-Clause. GitHub's commit tarball has
SHA-256 `356b1bac9eab9cd51fad729b844d84c6a7601560b219868f26888457975ade1d`.
For reproducibility, `git archive --format=tar` from a checkout of that commit
has SHA-256 `22664035118f2179a89fbc255a0323e862d6e36b9cefd64ac9bcf9f75acf75c7`.

Rust and Cargo are not application, package, test, or CI dependencies. The
language-neutral fixtures are permanent verification inputs; the disposable
upstream checkout used during initial development is not retained.

`RandCompatible.swift` is an independent Swift translation of the deterministic
behavior exposed by the Rust `rand` project's `StdRng`/shuffle APIs and its
ChaCha12 generator (`rand_chacha`). The initial oracle resolved `rand` 0.10.2.
The `rand` and `rand_chacha` projects are available under either the MIT License
or the Apache License, Version 2.0, at the user's option. No Rust crate is linked
or distributed by this Swift package.
