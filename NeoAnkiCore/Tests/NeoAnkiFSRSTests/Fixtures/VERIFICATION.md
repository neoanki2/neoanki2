# FSRS Swift port verification report

Reference: `fsrs-rs` commit
`6f5498f8dd1a95c781fcdd4448f28f16dd9e377d`, manifest version 6.6.2.

Status: verified on 2026-08-16.

The disposable oracle was built from the exact pinned source with:

- `rustc 1.97.1 (8bab26f4f 2026-07-14)`;
- `cargo 1.97.1 (c980f4866 2026-06-30)`;
- resolved `rand 0.10.2` (the pinned manifest requirement is `0.10.1`).

Verified in permanent native Swift tests:

- 21-parameter default model and scalar Float forward transitions;
- initial state reference vector from upstream documentation;
- integer elapsed-day input and raw fractional intervals;
- same-day short-term, success, failure, and clamp branches;
- coupled parameter clipping and monotonic S0 handling;
- expanding-prefix dataset construction, intraday context retention, interday targets;
- recency-weighted log loss, Brier score, and RMSE bins;
- defaults/S0 low-data optimizer branches;
- handwritten analytic derivatives, independently checked by finite differences;
- exact seed-2023 ChaCha12/rand shuffle permutations;
- exact card-aware batch structure and prediction placement;
- Double Adam and cosine-annealing primitive outputs;
- complete deterministic five-epoch optimizer output;
- final parameter absolute difference no greater than `1e-4`;
- evaluation log-loss absolute difference no greater than `1e-6`.

The permanent inputs are `reference-next-states.json` and
`optimizer-reference.json`. Their hashes, the two reproducibly defined upstream
archive hashes, toolchain identity, tolerances, and signing metadata are recorded
in `verification-manifest.json`. Tests decode the fixture files directly and
recompute each fixture SHA-256, so stale or edited oracle data fails verification.

Rust and Cargo are not application, package, test, CI, or release dependencies.
The temporary checkout, executable, instrumentation, Cargo artifacts, scripts,
and isolated toolchain were deleted after these fixtures passed.
