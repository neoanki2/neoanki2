---
title: Native library and maturity implementation evidence
description: Designs, behavior corrections, measurements, and acceptance evidence for the two selected codebase review recommendations.
audience: developer
---

# Native library and maturity implementation evidence

This implements S1 (shared native command/read policy) and P1 (bounded maturity reads) from the [comprehensive review](codebase-review-2026-11-16.md). The [decision record](../adr/0002-native-library-commands-and-maturity.md) explains the resulting boundaries and alternatives. The existing pending study-answer changes are included and verified together with this work.

## Acceptance evidence

The optimized comparison uses the investigation's 100,000-item/12,000-review synthetic library on the same Mac, Swift toolchain, and SQLite fixture. Cold-card measurements construct a fresh connection and empty maturity projection against the already prepared library; schema/bootstrap work is outside the timed read phase. Each side has 101 repetitions, with the first treated as warmup and 100 retained. Aggregate memory measurements use five fresh processes per side.

| Gate | Baseline | Candidate | Requirement |
| --- | ---: | ---: | --- |
| Cold single-card maturity, median | 1,333.48 ms | 1.86 ms | At least 10× faster |
| Cold single-card maturity, p95 | 1,617.67 ms | 2.28 ms | At most 50 ms |
| Aggregate phase incremental peak live allocations, median | 206,554,640 bytes | 55,759,856 bytes | At least 30% lower |
| Aggregate scope-summary latency, median | 2.792 s | 2.979 s | At most 10% regression |

The final candidate reduces attributable peak live allocations by 73.0%. This uses `malloc_zone_statistics` live bytes sampled every millisecond, measured above a baseline taken immediately before the aggregate read. It is phase-specific allocator evidence, not lifetime process RSS. The sampler can miss transients shorter than its interval. Instruments Allocations could not attach in this headless session; its original failure log is retained. The isolated measurement copy disables background automatic maintenance in both variants; production source contains no diagnostic bypass. Aggregate median latency increased 6.7%, within the 10% gate. Final measurements and source hashes are packaged with the evidence archive linked below.

Correctness tests cover injected second-move failure with complete rollback and no journal events; stale selection rejection with concurrent content preservation; import attachment failure rolling back rows/cards; parent-before-child nested import; duplicate/missing/cyclic graph rejection; receipt-write failure rolling back the mutation; post-commit failure recovering a receipt; exact portable import result recovery across connections; and explicit maturity failure without losing native browsing or study access.

Projection tests assert scoped decoding, no card/history replay on deck rename, affected-card grade/revert invalidation, journal-gap rebuild, external scheduler-origin changes, reset/suspension behavior, and preservation of unrelated scoped reads when another card's history is damaged. Existing API, synchronization, media, migration, and study suites remain release checks.

Verification completed: `swift build`, the complete `./Scripts/test-fast.sh` workflow, the 86-operation API reference check, documentation validation for 53 features, and unsigned iOS app/widget builds passed. The focused typed-answer XCTest passed on its first attempt (one test, no failures or skips), and its disposable Simulator was deleted. Original logs are included in the implementation evidence archive.

## Migration and release criteria

No persistent maturity cache, schema migration, external endpoint change, or file-format change is introduced. Existing libraries calculate the new disposable projection on demand. Selection moves now reject partial/stale selections rather than reporting partial success. Imports into a deck now commit placement and type membership together. Native recovery displays maturity as unavailable when evidence is damaged, and post-commit cleanup cannot convert a saved import into a failed operation.

The implementation must pass the supported fast/headless checks, generated API reference and documentation validation, unsigned iOS app/widget builds, and the focused typed-answer Simulator XCTest. The release uses one merged `main` revision and the unified controller. Shared dependencies affect iOS, Mac App Store, and Homebrew. Store processing/review and public availability are reported separately. Complete and verify the Mac upgrade and paired-iPhone update, then clean only the successful release's disposable outputs while preserving receipts, original logs, and debug symbols.

Rollback uses the release controller's recovery rules and a forward version containing a reviewed revert; it must not downgrade a published channel. Since persistent formats remain unchanged, reverting this implementation does not require data conversion. Do not retry an uncertain import/upload/install without reconciling its receipt first.

[Original investigation evidence](codebase-review-2026-11-16-evidence.tar.gz) and [implementation evidence](native-library-implementation-2026-11-16-evidence.tar.gz) preserve synthetic measurements and verification logs without production learner data.
