---
title: Mac statistics navigation performance
description: Retain reports across navigation and validate cached statistics without rescanning the library.
audience: developer
parent: Developer Guide
---

# Mac statistics navigation performance

Date: 2026-11-19.

## Cause and behavior

The Mac detail branches constructed fresh statistics models when switching between
All Decks and Statistics. Each view's observation task forced a full source read
and projection, discarding the previous snapshot. Home also needs statistics for
its Today and Upcoming panels, so both directions repeated that work.

`ContentView` now owns a `StatisticsWorkspace` for the scene. It retains separate
Home and report models, including filters and completed scenarios, in a bounded
eight-context LRU. Both destinations share one immutable source cache; concurrent
cold requests share the same read. Standalone feature-factory clients keep their
existing independent model ownership.

Reappearance validates the database revision without changing loading state.
An unchanged snapshot younger than 30 seconds needs no projection. Older snapshots,
filter changes, backward clock changes, calendar changes, and study-day rollover
reproject cached evidence. A changed revision reloads the source. Existing content
stays visible during refresh; explicit Retry bypasses the cache. Missing revision
support disables reuse rather than risking indefinitely stale data.

The revision reads SQLite's connection-local write counter and `data_version` in
constant time. This covers scheduling inputs outside the API/evidence journals,
as well as commits from other connections. Empty statistics-evidence queues no
longer open write transactions, keeping ordinary source reads revision-neutral.
Revision checks surround source loading and projection so concurrent commits
cannot stamp old evidence with a newer revision. Rapid filter edits coalesce and
discard obsolete results. No schema or HTTP contract changes are required.

## Measurements

Apple silicon macOS host, SwiftPM Release optimization. Each fixture contains one
card per item and 32 graded cards. Fixture construction is untimed. The comparison
uses the same production code and immutable fixture: fresh models with forced
refreshes versus the retained workspace with revision validation. It isolates the
navigation lifecycle improvement; it is not an exact checkout-to-checkout baseline.

| Cards | Recreated models, median | Recreated models, p95 | Retained models, median | Retained models, p95 |
| --- | ---: | ---: | ---: | ---: |
| 1,000 | 42.592 ms | 43.819 ms | 0.055 ms | 0.084 ms |
| 5,000 | 183.319 ms | 187.680 ms | 0.065 ms | 0.095 ms |

One sample refreshes both Home and the report. Each flow discards one warmup;
recreated models have five measured samples and retained models have 30. Retained
samples assert unchanged snapshot timestamps, verifying that they skip projection.
These are headless model timings, excluding SwiftUI rendering. The first report
still needs an initial projection, and data changes can require a full source read.

Raw samples, the Release executable source, and the build log are retained locally
under `.build/performance/mac-statistics-navigation-2026-11-19/`. The isolated
executable links production Core, Application, and Features products. Root Release
tests currently have an unrelated `UITestControlTests` reference to DEBUG-only
`UITestCommand`, so this measurement does not depend on compiling that test target.

The committed opt-in model benchmark uses the regular performance harness:

```bash
NEOANKI_RUN_PERFORMANCE_TESTS=1 NEOANKI_PERF_SCALE=medium \
  NEOANKI_PERF_JSON="$PWD/.build/performance/statistics-navigation.ndjson" \
  swift test --filter perfStatisticsRoundTripNavigation
```

This command runs the Debug test configuration; its timings are not the Release
numbers above.

## Verification

- `./Scripts/test-fast.sh` passed, including Core and all root-package tests,
  API freshness, architecture, release-tool contracts, and documentation checks.
- `./Scripts/build-ios.sh` passed for the shared model and view changes.
- The opt-in benchmark passed with a 1,000-card fixture.
- Focused tests cover no loading notifications on repeat visits, shared reads,
  bounded retention, filter independence, completed scenarios, cancellation,
  revision changes during loading, retry and error retention, unsupported revision
  providers, clock/calendar changes, and rollover.
- Core tests verify stable warm-read revisions and invalidation for local scheduler
  settings and unjournaled scheduler writes from another connection.

No graphical applications were opened, and no installed app was replaced.
