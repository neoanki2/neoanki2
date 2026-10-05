---
title: Tests and validation
description: Run NeoAnki2's fast checks, focused suites, documentation gates, and platform builds.
audience: developer
parent: Developer Guide
permalink: /user/developer/testing/
---

# Tests and validation

## Fast contributor loop

From the repository root, run:

```bash
./Scripts/test-fast.sh
```

This runs NeoAnkiCore unit and flow tests, app-model tests, application and sync
policy tests, architecture-boundary checks, Spotlight-safe Xcode path checks,
release-workflow reconciliation tests, the generated API-reference check, and
documentation validation.

The fast headless lane is designed to finish inside five minutes on a fresh CI
runner. The complete protected gate also includes real UI automation and has a
larger latency budget; it must not be represented as a sub-five-minute check.

## Focused suites

```bash
swift test --filter NeoAnkiAPITests --parallel
swift test --filter NeoAnkiFeaturesTests --parallel
swift test --filter NeoAnkiApplicationTests --parallel
swift test --filter NeoAnki2Tests --parallel
(cd NeoAnkiCore && swift test --parallel)
```

Use the narrowest relevant suite while iterating, then run `test-fast.sh`
before proposing a change. UI and performance workflows are slower and have
dedicated scripts under `Scripts/`; their GitHub Actions jobs remain the source
of truth for release acceptance.

### Headless sync regression and stress tests

```bash
./Scripts/test-sync.sh
./Scripts/test-sync.sh --stress
NEOANKI_SYNC_FUZZ_SEED=99 NEOANKI_SYNC_FUZZ_STEPS=200 ./Scripts/test-sync.sh
```

The default run includes eight fixed state-machine seeds and focused regression
tests. Stress mode uses 32 seeds with 200 actions per seed; set
`NEOANKI_SYNC_FUZZ_SEEDS` and `NEOANKI_SYNC_FUZZ_STEPS` to adjust it, up to 128
seeds and 1,000 actions. A failure reports its seed, operation trace, and differing
resources. Replay the seed with the same step count. Mutation choices, input IDs,
timestamps, injected failures, and delivery shuffles are seeded; persistence
still generates its own library, card, and review IDs.

Three real temporary SQLite libraries synchronize through an in-process server
with independent change tags. The model checks convergence, exact item/review
counts, expected edits, preserved scheduling data, and a quiet journal after
settling. It injects offline starts/fetches, failed sends, partial commits with
lost acknowledgments, duplicate deliveries, reordered dependencies, and process
restarts. Separate tests cover initial library collisions, persistent type
aliases, edit/delete conflict recovery, corrupt payloads/assets, durable inboxes
and upload queues, legacy metadata, stopping in-flight sync, acknowledgment races,
and merge permutation/idempotence properties.

These tests run in the normal application test lane of `test-fast.sh`. They do
not touch the installed apps, user library, iPhone, Apple account, or live iCloud
container. They verify the repository and transport decisions headlessly;
Apple provisioning, push delivery, and SDK/server integration remain platform
acceptance checks rather than claims made by the simulated server.

For a UI-bearing release, run its targeted journey and then all seven local UI
journeys before the first push:

```bash
./Scripts/run-ui-tests.sh FastFunctionalJourneyTests/testRelevantJourney
./Scripts/run-ui-tests.sh
```

If local UI automation is unavailable, stop before release rather than using
remote CI as the first functional UI pass.

## Required CI UI plan

`Config/ci-ui-shards.json` is the executable source of truth for required UI
coverage. macOS builds the app and test runner once, then runs five balanced
functional shards from that exact-revision artifact. iOS also builds once:
behavioral journeys run on the representative large phone, while the complete
accessibility and responsive-layout matrix runs on both the compact phone and
iPad. Small iOS shards run concurrently on separate hosted runners, with one
simulator per shard. Do not use parallel simulator clones inside a job: they
compete for Accessibility and can turn fast assertions into AX IPC timeouts or
test-runner bootstrap crashes.

`FunctionalUICoverageManifestTests` compares the manifest with every declared
macOS and iOS UI test method. Removing, renaming, or failing to schedule a test
therefore fails the fast test lane. Accessibility tests must remain assigned to
both compact and regular-width devices. Assertion failures are not retried;
the mobile runner retries only when XCTest records that no test started.

Each shared build and UI shard writes its elapsed time to the Actions step
summary. When adding coverage, rebalance existing shards before adding another
macOS job: standard GitHub-hosted plans allow only five concurrent macOS jobs,
so excess sharding creates queue time instead of faster feedback.

Keep the intrinsic runtime of each required UI shard below five minutes. Split
long iOS groups before adding in-process simulator workers; CI-level isolation
is both faster and more reliable for Accessibility-heavy journeys. Use
stable completion state for async work rather than waiting for transient busy
indicators, combine accessibility audit kinds into one tree traversal, and use
short-cadence waits that evaluate the ready state immediately. Put exhaustive
enum and input combinations in parameterized Swift tests; UI journeys should
prove that every option is exposed and exercise representative mutations
through the real control. This preserves behavior coverage without repeating
the same expensive accessibility snapshots and menu choreography.

## Mobile visual acceptance

The redesign journeys assert actual navigation destinations, default answer
concealment, scoped Library triage, both grading modes, undo/skip, local recording
persistence, all seven interactions and five layouts, builders, transfer, and
focused authoring. The inventory journeys retain named screenshots and matching
accessibility trees in the XCTest result bundle. The authoring journey also
covers rich text, cloze clearing, media removal, and native picker cancellation.
It checks that editing mixed rich-text runs preserves semantic formatting,
including color, size, code, and links. Text editor heights scale with Dynamic
Type; media status labels wrap within their rows.

Use uniquely named disposable devices for headless `xcodebuild`/XCTest runs and
always shut down and delete them in a cleanup trap. Never open Simulator.app or
use an existing user-managed device. Run the complete phone suite, then cover
compact phone and iPad with light/dark inventory, largest Dynamic Type, Increased
Contrast, Reduce Motion, rotation, keyboard, and long-content cases. Compare the
rendered screenshots; passing accessibility audits alone is insufficient.
Physical-device media capture and signed CloudKit checks remain separate
acceptance work. Reset-only recovery fixtures exercise the real SQLite conflict
restore adapter, failed restores, resolution, malformed import parsing, and the
shared startup error presentation with Retry. The startup fixture injects an
error message; it does not simulate database corruption. Contrast audits scroll
target text into view and retain diagnostic attachments for fixture text clipped
vertically by a scroll viewport. Controls, visible text, horizontal overflow, hit
regions, and descriptions remain strict.
Horizontal bounds checks measure controls, text, images, and named groups;
unlabeled native Form backgrounds may draw beyond the scrolling content bounds.

## Documentation checks

```bash
swift run neoanki-api-reference check
swift Scripts/validate-docs.swift --require-screenshots
```

The protected **Documentation and screenshot gate** must pass before `main`
can advance. See [maintaining documentation](../documentation/) for generation
and screenshot ownership.

That workflow also builds and crawls the Jekyll output, then runs
`Scripts/check-docs-responsive.mjs` in headless Chromium at 375, 768, and 1024
pixels. It checks keyboard navigation, contained code blocks, and the absence
of page-level horizontal overflow.
