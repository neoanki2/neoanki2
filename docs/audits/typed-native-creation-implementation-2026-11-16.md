---
title: Typed native creation and bounded study-head implementation
description: Compatibility, recovery, performance and verification evidence for the two selected review recommendations.
audience: developer
---

# Typed native creation and bounded study-head implementation

This implements the two selected [investigation recommendations]({{ '/audits/comprehensive-codebase-review-2026-11-16/' | relative_url }}). The [decision record]({{ '/adr/0004-typed-native-creation-and-study-heads/' | relative_url }}) describes the resulting boundaries. Existing pending vocabulary workflow changes and investigation cleanup are retained as release input.

## Resulting behavior

Native poem/prose creation passes a typed text draft into the existing authored semantic compiler and commits the prepared result without generated-package writes or JSON reparsing. One shared bounded writer enforces encoded source/line/part limits and supports the unchanged public bundle APIs. The two private families of wire structs and native temporary-file/import/placement sequences are removed. Domain poem/prose parsing, prompts, preview and existing typed editor reconciliation remain distinct.

Creation commits the selected parent, new deck, type ownership, items/cards and exact result receipt together. Parent disappearance, stale reused type definitions and precommit cancellation/failure leave no partial child. A retry with the same native command identity recovers the original result; another intentional creation receives fresh identities and reuses compatible schemas. Postcommit read/publication problems remain warnings rather than a reason to create again. These atomic-placement and recovery corrections intentionally strengthen the previous Mac/mobile divergence.

Ordinary unlimited new-head reads use the existing ordered active-new index globally; scoped reads retain planner choice to avoid regressing sparse decks. A covering negative work check avoids the card join when no ordered works exist. Any positive check retains the old scoped/due work path. Gate and selection share one SQLite read snapshot. Daily-limit and work-order routes, full queue validation, external APIs, persistent schemas and interchange formats remain unchanged.

## Optimized production-path measurements

Baseline is the investigation's pinned source at `5baf3fe` plus its captured pre-implementation edits. Candidate uses the implemented production ItemStore, SQLite repository and shared StudyFeatureModel. Both use the same synthetic SQLite fixture copies and fixed scheduling instant on Mac15,7 (12 cores, 36 GiB), macOS 27.2.1, Swift 6.4.2 and system SQLite 3.54.0. Sources, commands, sample output and process guards are retained locally under `.build/typed-builders-study-head/`.

Fixture construction, copy and bootstrap are outside timing. Each path excludes one warm-up. Short head paths retain 100 observations; expensive baseline head paths and full feature starts retain five. No build/test workload ran with timed probes. Values are warm medians; p95 is stated only with 100 retained observations. Head identities match between baseline and candidate at every scale.

| Cards | One-card fetch baseline / candidate | First-readable-card baseline / candidate | Fully prepared session baseline / candidate |
| --- | --- | --- | --- |
| 100 | 0.595 / 0.294 ms | 1.335 / 0.951 ms | 4.339 / 3.820 ms |
| 1,000 | 3.737 / 0.296 ms | 6.937 / 3.768 ms | 33.246 / 31.224 ms |
| 25,000 | 159.135 / 0.278 ms | 310.895 / 125.318 ms | 1,172.561 / 968.392 ms |
| 100,000 | 1,124.570 / 0.311 ms | 2,038.557 / 884.650 ms | 6,303.534 / 5,016.801 ms |

The 100,000-card candidate head p95 is 0.489 ms, within the 200 ms acceptance budget; its median is below 100 ms. The broader timings use the shared model's actual first-ready and total-preparation milestones, not rendered pixels. Full preparation still costs seconds at 100,000 cards. These measurements concern independent Basic cards; they do not imply the same gain for limited/work-heavy/mature libraries or physical-device rendering. Existing constrained/work paths retain contract coverage and conservative dispatch.

## Verification

The full Core and root Swift test lanes passed 1,269 tests, including native creation differential imports, schema reuse, atomic second-item failure, deleted parent, lost response/reopened receipt replay, request-hash conflict, cancellation, legacy registry fallback, encoded limits, compatibility-export symlink confinement, query plans, deterministic statement work and a held read snapshot with a concurrent writer. Existing authored/portable/media, scheduling, sync and API suites remained enabled. The unsigned iOS app/widget build passed.

The fast workflow's supporting contracts, architecture and API-reference checks passed. Its documentation stage initially found the regenerated feature index and ADR navigation missing; those documentation inputs were corrected and the documentation gate was rerun.
CI additionally required the affected sync, scheduling, item-type, troubleshooting
and CLI guides and claims registry to be reviewed; those were updated without
weakening the change-aware gate. Original logs are retained. Test setup corrections initialized the diagnostic SQLite connection and used WAL for the intentional concurrent-write fixture; assertions were retained. Stale generated XCTest signing bundles were rebuilt without weakening signing or stripping quarantine.

The implementation adds no file-format/schema migration. Publication uses the merged-main unified controller and one shared version. Store submission/processing/public availability, local Mac upgrade, verified iPhone update and completed-artifact cleanup are separate recorded outcomes; no publication or device result is implied by these test results.

[Implementation evidence archive]({{ '/audits/typed-native-creation-implementation-2026-11-16-evidence.tar.gz' | relative_url }})
contains original logs, raw timings, probe sources and the implementation diff.
