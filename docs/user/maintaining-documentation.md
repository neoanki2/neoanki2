---
title: Maintaining this documentation
description: Keep guides, high-risk claims, feature coverage, screenshots, and rendered pages synchronized with product behavior.
parent: Contributor Guide
---

# Maintaining this documentation

NeoAnki2 keeps user documentation beside the behavior it describes. Explanatory
articles are intentionally hand-written; a manifest and tests keep their
coverage verifiable.

The latest published assessment is the
[July 2026 documentation quality audit]({{ site.baseurl }}/audits/state-of-art-2026-07-27/).

## When product behavior changes

1. Update the relevant article under `docs/user/`.
2. Update `docs/features.json` if ownership, implementation files, tests, or
   screenshot coverage changed.
3. If a format, limit, compatibility requirement, storage location, scheduling
   default, or destructive consequence changed, update `docs/claims.json` and
   its production-backed test.
4. Regenerate the feature index:

   ```bash
   swift Scripts/validate-docs.swift --write
   ```

5. Run the fast checks:

   ```bash
   ./Scripts/test-fast.sh
   ```

On pull requests, a mapped source change must update its specific article.
Changing an unrelated feature record does not bypass this check. The inventory
boundary in `docs/features.json` also scans user-facing source and UI-test roots
for unmapped files with stable UI markers. Add a narrow exclusion only for
non-product infrastructure such as the screenshot capture suite.

`requiredScreenshotFeatureIDs` is the explicit minimum visual-evidence set.
Every listed feature must name a screenshot. With `--require-screenshots`, the
validator also compares the capture's source SHA with the current tree and
rejects an image when any source owned by that feature changed after capture.
Updating a hash or timestamp without recapturing the UI does not satisfy this
check.

When a mapped source diff is exclusively debug-only test infrastructure and
does not change production behavior, record the reviewed files, reason, and
exact patch SHA-256 in `docs/infrastructure-change-review.json`. The validator
accepts the review only when that file changes in the pull request and its hash
matches the current diff. Any later source edit invalidates the review.

## High-risk factual claims

`docs/claims.json` records facts where stale prose could cause failed imports,
data loss, incompatible builds, or incorrect scheduling expectations. Core and
app unit tests decode the registry and compare checkable values with production
constants, including media/import limits, portable format version, FSRS
defaults, storage location, and package requirements.

When adding a claim:

1. Give it one owning user article and the production source of truth.
2. Prefer a named production constant over copying a literal into a test.
3. Add a test comparison for values that code can expose.
4. For behavioral claims that cannot be a constant, cite the focused behavior
   test and keep the article's consequence and recovery language explicit.

## Review ownership and release triggers

The contributor changing user-visible behavior owns the matching article,
claim, feature record, and screenshot scenario in the same pull request.
Review documentation whenever a UI label, command, shortcut, format, limit,
default, file location, compatibility requirement, error, destructive action,
or accessibility behavior changes. Before release, a maintainer reviews the
rendered site, source revision label, screenshot provenance, and support path.

## Refresh screenshots

Documentation screenshots use isolated databases, deterministic test
scenarios, a 1024 × 680 minimum window, and dark appearance. Each image is
cropped to the focused NeoAnki2 app window, so the desktop, Dock, and menu bar
are not published. The capture pipeline converts the opaque matte outside the
native macOS window curve to transparent corners, so the window edge stays
clean against both light and dark documentation surfaces. Capture rejects
partially clipped expected controls. Images are not captured during normal
local testing.

1. Run the **Documentation screenshots** workflow on the pull request, dispatch
   it manually, or wait for its weekly run. Product-UI pull requests trigger it
   automatically so a fresh artifact is available before merge.
2. Download the `neoanki2-documentation-screenshots` artifact.
   It must contain all PNG files and `manifest.json`.
3. Review every image for correct content, layout, visible formatting and
   controls, and absence of private data. Also confirm that `manifest.json`
   names the expected source commit and capture time. This remains a required
   manual review; metadata validation does not approve screenshots.
4. Promote the reviewed directory:

   ```bash
   ./Scripts/promote-doc-screenshots.sh path/to/downloaded/screenshots
   ```

5. Run `swift Scripts/validate-docs.swift --require-screenshots`. When a feature
   source changed after the artifact's source SHA, capture and promote a newer
   artifact; never edit `sourceSHA` by hand.

Capture records each image's source SHA, UTC capture date, pixel dimensions,
scenario, and identifiers that were required to be visible. Both capture and
promotion reject a missing or malformed manifest, mismatched dimensions, or an
incomplete screenshot set. Promotion copies the reviewed manifest beside the
images in `docs/assets/screenshots/`.

The workflow never commits or promotes images automatically. This review step
prevents a UI failure, permission dialog, or runner-specific content from
silently replacing published documentation.

## What is generated

Only `docs/features.md` is generated. User instructions, format specifications,
and troubleshooting guidance remain curated because source comments cannot
capture workflow context, limitations, or user-facing language reliably.

Every documentation pull request builds Jekyll and runs the rendered-site
crawler. The crawler checks internal routes and fragments, assets, canonical
metadata, heading order, image alternatives, duplicate IDs, language, and
landmarks. The stable **Documentation and screenshot gate** job runs on every
pull request so branch protection can require one status regardless of changed
paths.

The only canonical public content site is `https://neoanki2.github.io/`. The
`neoanki2/neoanki2.github.io` deployment builds this repository's `docs/`
directory at the root URL. This repository's own Pages deployment contains
only route-preserving redirects from the legacy `/neoanki2` project URL and is
validated to contain no copied documentation assets. Deployment remains
restricted to `main`; the footer identifies the exact source revision and UTC
publication time used for the canonical build.
