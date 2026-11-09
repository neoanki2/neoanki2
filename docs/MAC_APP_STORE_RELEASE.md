---
title: Mac App Store Release
description: Prepare, sign, review, and submit the native sandboxed Mac app.
audience: developer
parent: Developer Guide
permalink: /MAC_APP_STORE_RELEASE/
---

# Mac App Store release

The native Mac app shares NeoAnki2's App Store Connect record and bundle ID
`com.neoanki2.ios` with iPhone and iPad. Homebrew retains its Developer ID
configuration and `com.neoanki2.app` identity. The Store configuration enables
App Sandbox, user-selected file access, microphone recording, loopback API
networking, and the existing private production CloudKit container.

The Store library lives inside its sandbox. Transfer an existing Homebrew library
through portable deck export/import or explicitly enabled iCloud sync.

## Resumable workflow

```bash
./Scripts/release-macos-app-store.sh prepare --version 1.0.1
./Scripts/release-macos-app-store.sh upload --version 1.0.1
./Scripts/release-macos-app-store.sh status --version 1.0.1
python3 Scripts/review-macos-app.py --candidate /absolute/path/to/candidate
./Scripts/release-macos-app-store.sh review-context --version 1.0.1
./Scripts/release-macos-app-store.sh submit --version 1.0.1
```

Receipts live under `.build/macos-app-store-release/`. `--output` selects an
explicit candidate directory; `--build` selects an unused numeric build number.
Changing source or release identity requires a fresh candidate. An uncertain
upload must be inspected in Apple processing before another upload attempt.

Saved signing inputs live outside the repository in the same signing directory
used for iOS. In addition to Apple Distribution material, export requires
`Mac-Installer-Distribution.cert.pem` and `Mac-Installer-Distribution.key.pem`.
A Mac App Store provisioning profile must authorize the distribution certificate,
shared bundle identity, production CloudKit, and push notifications. Signing uses
a disposable Keychain; no existing signing Keychain is unlocked.

## Candidate review

Finish the native Mac listing, screenshots, reviewer contact/instructions,
privacy declaration, category, age rating, and automatic release setting before
running `review-context`. Retain fresh `compliance-evidence.json` using the
[privacy evidence format](IOS_RELEASE.md). Historical rejection evidence stays
preserved; any rejection of this Mac version requires its actual Apple message,
attachments, and verified remediation.

`internal-review.json` binds the exact context hash and inspectable evidence to
two distinct reviewers. Product observations cover `fresh_install`,
`primary_journey`, `macos_layout`, `permissions`, and `imports_exports_sync`.
Compliance observations cover `metadata`, `screenshots`, `privacy`, `age_rating`,
and `rejection_remediation`. Each report must approve the exact context with no
blocking findings, and retain its actual transcript.

The `ui_runs` collection includes the production run's `review.json`, its actual
`.xcresult`, and `production: true`. The ordinary optimized sandboxed app must
pass `MacStoreProductionReviewJourneyTests/testFreshInstallCreateStudyAndPersistence`
without fixture arguments. Use an isolated macOS test account if the Store
container already exists; the review runner never deletes a user's library.

Each uploaded screenshot must have its Apple ID, retained local path and SHA-256
in `screenshots`; the gate compares Apple's checksum to the actual local pixels.
Both `internal-review.json.acceptance` and `acceptance.json` require passed,
checksummed evidence for `production_cloudkit`, `sandbox`, and `macos_ui`. The
first uses `{passed, evidence: {path, sha256}}`; the latter uses
`{passed, evidence_file, sha256}`, together with `source_sha256` and `build_id`.
Mac checks cannot be waived. No report may turn an unperformed check into a pass.

Report uploaded, submitted, Apple-approved, and publicly available states
separately. Automatic release does not establish approval or storefront
availability.

## Hosted native review

When local macOS XCTest cannot enable automation mode, the existing Release
candidate workflow has an isolated `mac_store_review_tag` mode. It downloads a
checksummed signed app from an unpublished draft release, checks out the exact
internal candidate source, and runs the ordinary sandboxed journey on a fresh
hosted Mac. No Apple signing key is provided to that job. The existing privileged
packaging/attestation path is skipped in review mode.

Use the stable `/tmp/neoanki2-mac-store-review/candidate` and
`/tmp/neoanki2-mac-store-review/review` paths both locally and on the runner so
retained receipts and xctestrun paths remain unchanged when results are downloaded.
The runner configures an actual supported display mode and enters Full Screen
through the standard keyboard command; screenshots retain the actual app pixels.

The ordinary native journey also selects an external authored deck through the
Open panel, verifies its image in study, exports through the Save panel and checks
the package contents, cancels both panels, records and plays a real microphone
response, verifies its persisted audio after restart, and enables the local API
through Settings to check actual loopback health, authentication, and shutdown.
These checks run after the five listing captures and never seed app storage.

The hosted fixture creates a temporary 1440 × 900 virtual monitor when the VM's
fixed display cannot provide an accepted Store size. The monitor is the actual
WindowServer main display throughout XCTest; the helper restores the original
geometry and releases it when the child exits. This CI-only tool uses private
CoreGraphics display interfaces and is never linked into or bundled with the app.
It refuses to run outside an isolated GitHub-hosted Mac.

The display helper is fetched from the workflow event's exact revision, while
checkout and app review remain bound to the `head` input. This lets review
infrastructure fixes test an already signed released candidate without changing
its source or binary. Preserve `environment/tooling-revision.txt`, `display.log`,
and the original `review/` directory together. Download the artifact into
`/tmp/neoanki2-mac-store-review` to retain those original paths. Resume Store
commands from a detached checkout of the candidate's released source if the
working branch has subsequently changed only review infrastructure.

The optional `ios_service_probe` mode records both XCTest service states on an
owned disposable iPad Simulator, before and after activating testmanagerd. It
runs no UI validation and never starts packaging, signing, or publication jobs.
Use its raw launchctl observations to diagnose initialization failures before
changing or revalidating the readiness gate.
