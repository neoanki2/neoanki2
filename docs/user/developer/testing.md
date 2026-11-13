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
runner. The protected gate also includes shared-platform builds and an unsigned iOS
archive. Native XCTest UI journeys do not run automatically in CI.

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
dedicated scripts under `Scripts/`. The [unified release process](../../RELEASING.md)
selects relevant headless checks; UI journeys are additional targeted evidence,
not a ceremony required for every release.

### Chrome companion

The extension needs no build step. Its JavaScript and packaged-browser checks run
separately from the Swift fast lane:

```bash
cd Extensions/Chrome
npm ci
npm test
npx playwright install chromium --no-shell
npm run test:integration
```

The integration test loads the production extension into headless Chrome for
Testing with a disposable profile and a real, isolated NeoAnki2 API server. It
checks pairing, selection capture, dictionary suggestions, study-card creation,
and replay after a lost save response. See the extension README for fixture
cleanup and the [user guide]({{ '/user/chrome-companion/' | relative_url }}) for local installation.

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

For an explicitly requested UI investigation or a change requiring visual
regression evidence, run its focused journey:

```bash
./Scripts/run-ui-tests.sh FastFunctionalJourneyTests/testRelevantJourney
```

These optional journeys are separate from the unified release critical path.
Do not add all UI journeys, screenshot capture, or physical acceptance to an
unrelated release. Failed checks retain their evidence and require a diagnosed
application, test, or workflow correction before another validation run.

## CI reliability and optional UI investigations

Automatic CI runs all root-package Swift tests and all NeoAnkiCore tests,
architecture and release contracts, documentation checks, shared macOS/iOS
builds, and the unsigned iOS app/widget archive. Performance benchmarks remain
opt-in. No native XCTest UI test, screenshot capture, or screenshot-promotion
workflow runs automatically. The launch smoke test was deleted: it slept for two
seconds and accepted both normal exit and a crash, providing no readiness check.
The obsolete test of the retired release orchestrator was also deleted; the
current controller is covered by `Scripts/test-release.py`.

Hosted UI runs failed across unrelated tests in screenshot requests, orientation
confirmation, application launch, accessibility audits, keyboard focus, and
native menu actions. Examples include Actions runs `42831394331`, `42821536861`,
`42730552467`, `42716879402`, and `42995563218`. These failures persisted after
simulator isolation and removal of private-service prewarming. Removing the UI
jobs removes continuous end-to-end verification of navigation, editing, media,
lookup, study, transfers, Studio, occlusion, layouts, and accessibility on Mac,
iPhone, and iPad. Headless model and contract tests cover behavior but do not
replace real-control, pixel-contrast, layout, or assistive-technology evidence.

`Config/ci-ui-shards.json` remains the inventory for explicit investigations.
`FunctionalUICoverageManifestTests` checks that it covers the declared journeys;
it does not schedule them in CI. Use the existing CLI runners for a relevant,
explicitly requested investigation. Each mobile run owns one disposable Simulator
and cleans it up on exit. Failed assertions and infrastructure errors fail that
run without retries or skipped-test success.

Documentation CI still verifies committed screenshot files, checksums,
dimensions, provenance metadata, and display density. Screenshot freshness
against application source is opt-in through `--check-screenshot-freshness`;
UI source changes no longer require a hosted capture or an automatic bot commit.
This removes automatic visual freshness coverage. Refresh screenshots through
the capture and promotion scripts when explicitly requested.

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

The image attachment paste/save/replace regression owns the `phone-image-attachments` shard so no iOS batch exceeds five cases. Native Mac Store first-launch acceptance runs separately through `Scripts/review-macos-app.py` against the signed sandboxed candidate.

### iOS XCTest startup

Mobile XCTest setup verifies portrait interface geometry from a Simulator-contained
screenshot before launch. It requests an orientation change only for landscape,
square, or explicitly upside-down state, then verifies portrait dimensions again.
This avoids waiting for a redundant portrait confirmation on a cold Simulator
that already displays portrait pixels. Both occlusion cases and their assertions
remain available for focused investigations; this setup correction adds no case retry or timeout increase.

The optional UI runner, ordinary Release review, and App Store screenshot capture boot a
uniquely owned disposable Simulator with `simctl bootstatus -b`, then invoke
`xcodebuild test-without-building` with the verified `.xctestrun` and destination.
Xcode owns test-runner initialization. The supported split-build workflow is
[documented by Apple](https://developer.apple.com/library/archive/technotes/tn2339/_index.html).

Manual `launchctl kickstart` of private XCTest/AutomationMode services is an
optional diagnostic, not a prerequisite for UI validation. The former required
prewarming gate timed out before any UI case ran, including after cache
preparation; it depended on undocumented service labels and endpoint state.
Removing that gate removes no product tests. For explicit UI investigations, selected test counts, result bundles, and
disposable-device cleanup remain required. An actual XCTest initialization
failure still fails validation and must be diagnosed before another run.
