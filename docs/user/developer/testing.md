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
the generated API-reference check, and documentation validation.

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
