---
title: Mobile due-count freshness and performance
description: Verify immediate local due counts, cache correctness, compatibility, and measured host latency.
audience: developer
parent: Developer Guide
---

# Mobile due-count freshness and performance

Date: 2026-11-19.

## Behavior

Foreground entry marks the previous count as checking synchronously, then validates
local availability before broad Home reads or network synchronization. Home totals,
deck rollups, Unassigned, and the open scope publish together. Full Home snapshots
cannot replace the separate availability state. Failures offer retry rather than
zero. The next due date or study-day rollover drives foreground count refreshes.
Sync status retains its own lightweight foreground polling; it does not reload the
library.

The optional `LibraryDueSnapshotReading` capability preserves existing repository
conformers. Production uses one dedicated SQLite actor/connection, an in-memory
revision/calendar-aware cache, and the existing eligibility rules. Count queries
carry only scheduling identifiers, avoid ranking unlimited decks, and traverse
related cards once per exclusion check. The existing writer repairs explicitly
dirty family/template projections; database errors are not retried.

The connection opens an ordinary file descriptor and enforces read-only SQL using
[SQLite query-only mode](https://sqlite.org/pragma.html#pragma_query_only).
Opening its descriptor with `SQLITE_OPEN_READONLY` reproduced writer/backup lock
failures on this host (`SQLITE_IOERR_LOCK`, errno 9). A regression test verifies
that the query-only reader rejects writes while the writer and backup connections
remain usable.

Cache expiration and the next actual study opportunity are separate values.
Widgets retain their scoped family counts and actual next-study time; conservative
cache rollover must not become a fabricated “Next” date. Device publication is
asynchronous and does not gate visible counts or review commits. No schema,
HTTP endpoint, or interchange-format migration is introduced.

## Optimized host measurements

Apple silicon macOS host, SwiftPM Release optimization. These are repository/model
timings, not physical-iPhone measurements or rendered-frame timings. Each reported
p95 uses 30 samples after one warmup. Fixture construction is outside measurement.
Each Core fixture adds 12 related-card examples to the nominal scale.

| Cards | Zero to 32 due review cards, recalculated | Validated cache hit | Mostly new cards, nested limits, recalculated |
| --- | ---: | ---: | ---: |
| 1,012 | 1.46 ms | 0.10 ms | 7.75 ms |
| 25,012 | 1.99 ms | 0.12 ms | 415.69 ms |
| 100,012 | 6.92 ms | 0.14 ms | 3134.32 ms |

The production-library request-to-observable-model benchmark with exactly 1,000
independent cards measured **5.34 ms median / 5.64 ms p95**.
The timer-boundary fixture first verifies zero cards with an expiration at the due
instant, then verifies 32 after crossing it. Recalculation samples move the reference
time backward within an otherwise unchanged interval and assert the snapshot's
calculation time, so they cannot silently measure cache hits.

The mostly-new fixtures include review history, related families, nested decks,
and parent/child daily limits. The scheduled-review phase seeds coherent persisted
schedules directly, leaving exactly 32 due; it does not simulate 100,000 user review
transactions. Existing availability and Home paths are also recorded as references.

The original 100 ms stretch target is met for the return-to-practice workload,
including the 100,000-card library. It is **not met** for bulk new-card admission
with nested limits. That workload still evaluates exact family/budget eligibility
across many due candidates; the UI shows checking during a cache miss. The cache
only reuses verified results within their validity interval.

Raw NDJSON, summary statistics, and validation logs are retained locally under
`.build/performance/mobile-due-counts-2026-11-19/` (ignored build evidence).

## Verification

- `./Scripts/test-fast.sh` passed, including API reference freshness, architecture,
  background refresh, badge contracts, and documentation checks.
- The final focused Release Core suite passed: 10 tests, including seeded mixed
  forests compared with actual study queues, review/undo, suspension, deck moves,
  synchronization, clock/calendar changes, exact due/rollover boundaries,
  cancellation, read-lane isolation, and backup/write compatibility.
- Feature tests cover synchronous checking on foreground entry, coalescing,
  superseded reads, retry, boundary timers, commits during startup, stalled Home
  reads, and widget scope/next-study compatibility.
- The badge test now permits broader Home work to remain active after fast counts
  publish; fresh-count, study-start, and eventual-completion assertions remain.
- `./Scripts/build-ios.sh` passed for the unsigned iOS Simulator app. No desktop
  GUI interaction or physical-device installation was performed.

An exploratory full root-package Release test build encountered the existing
`UITestControlTests` reference to DEBUG-only `UITestCommand`. Production model
latency was therefore measured using an isolated Release executable linked to
`NeoAnkiFeatures`, `NeoAnkiApplication`, and `NeoAnkiCore`. Its request/publication
boundary is also covered by `ForegroundDuePerformanceTests.swift`.

Reproduce the Core measurements from `NeoAnkiCore/` with
`NEOANKI_RUN_PERFORMANCE_TESTS=1 NEOANKI_PERF_SCALE=medium swift test -c release --no-parallel --filter perfForegroundDueCounts`.
Use `large` or `stress` with `NEOANKI_PERF_ALLOW_SLOW=1` for the larger fixtures.
