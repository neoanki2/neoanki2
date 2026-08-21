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
iPad. Independent iOS methods use isolated simulator clones so they can execute
in parallel.

`FunctionalUICoverageManifestTests` compares the manifest with every declared
macOS and iOS UI test method. Removing, renaming, or failing to schedule a test
therefore fails the fast test lane. Accessibility tests must remain assigned to
both compact and regular-width devices. Assertion failures are not retried;
the mobile runner retries only when XCTest records that no test started.

Each shared build and UI shard writes its elapsed time to the Actions step
summary. When adding coverage, rebalance existing shards before adding another
macOS job: standard GitHub-hosted plans allow only five concurrent macOS jobs,
so excess sharding creates queue time instead of faster feedback.

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
