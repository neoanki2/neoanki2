---
title: iOS Release Checklist
description: Build, provision, verify, and upload NeoAnki2 for iPhone and iPad.
audience: developer
parent: Developer Guide
permalink: /IOS_RELEASE/
---

# iOS and iPadOS release checklist

NeoAnki2 supports iOS/iPadOS 17 and newer. Local signing is team-neutral. The
repository contains the real application and widget targets, privacy manifest,
usage descriptions, icon, launch configuration, entitlements, versions, and
App Store Connect export options.

## Automated preflight

The resumable App Store workflow is separate from the macOS/Homebrew release:

```bash
./Scripts/release-ios.sh prepare
python3 Scripts/capture-ios-app-store.py
./Scripts/release-ios.sh upload
./Scripts/release-ios.sh status
./Scripts/release-ios.sh review-context
# Complete the independent internal reviews described below.
./Scripts/release-ios.sh submit
```

`prepare` runs fast, sync stress, and release safety tests, then creates an
unsigned Release archive. `export` obtains App Store profiles and uses the
saved distribution identity in a disposable Keychain to export an IPA.
`upload` validates and delivers it; `submit` reconciles Apple's review resources
and submits only the exact accepted build with automatic release enabled.
`--prepare-only` aliases `prepare`; `all` runs preparation, upload, and submission
until an external requirement blocks progress. Apple processing is checked with
`status`; resume `submit` after the build is valid.

Each source snapshot has an artifact directory under `.build/ios-release/`.
The command prints its `release.json` receipt and `IOS_RELEASE_*` telemetry.
Keep the directory for resume. Source, version, or explicit build changes require
a new directory; `--output` selects it. An uncertain upload is never retried
automatically. Inspect Apple processing and the saved delivery log first.

## Mandatory internal App Store review

Apple approval cannot be guaranteed. Internal review prevents submission with
known unresolved defects, missing rejection evidence, stale screenshots, or a
review of a different candidate. It does not replace Apple's review or turn
unperformed physical tests into passes.

After attaching the processed build and finishing the listing, run
`review-context`. This read-only stage records `review-context.json` and prints
`IOS_RELEASE_REVIEW_CONTEXT_SHA256`. The context binds the full source snapshot,
production binary inputs, test harness inputs, exported IPA, Apple build/version,
live listing localizations, app name/subtitle/category, age-rating declarations,
reviewer instructions, and ordered screenshot assets.
The submission command fetches those Apple values again; any change invalidates
the review. Finish all source and listing edits before reviewing.

Place `compliance-evidence.json` in the artifact directory with `app_id`,
`observed_at` (UTC ISO timestamp), and `privacy` containing `source: "App Store
Connect"`, the exact `declaration`, and checksummed `evidence` (`path`, `sha256`)
captured from the current App Privacy screen. Include a `limitations` list
explaining that the browser-only privacy declaration cannot be compared live
through the API. Evidence must have been observed within the preceding 24 hours;
an old screenshot is insufficient. This freshness rule reduces stale evidence
but cannot detect a remote declaration changed after observation. The compliance
reviewer must inspect the actual declaration against the candidate's behavior.

Use two distinct independent reviewers: one for product behavior and one for
App Store compliance. Give each the exact context and inspectable evidence.
Retain their actual review transcripts as well as structured reports. A report
must name its reviewer and role, reference `context_sha256`, set
`decision: "approve"`, contain `blocking_findings: []`, and include substantive
`observations` with a `scope`, concrete `detail`, and `evidence_ids` for each
required scope:

- Product: `fresh_install`, `primary_journey`, `ipad_layout`, `permissions`,
  `reminders_widgets_sync`.
- Compliance: `metadata`, `screenshots`, `privacy`, `age_rating`,
  `rejection_remediation`.

Evidence must establish the claimed scope. For example, test screenshots cannot
prove a published privacy declaration; cite the exact account evidence instead.
Reviewers should report limitations explicitly and reject unexplained product or
compliance gaps. Checksums establish integrity, not reviewer authentication;
never fabricate a report, relabel a mock test as production, or accept a bare
`passed: true` checklist. Physical waivers retain the separate restrictions below.

Place `internal-review.json` in the candidate artifact directory:

```json
{
  "schema_version": 1,
  "context_sha256": "HASH_PRINTED_BY_REVIEW_CONTEXT",
  "evidence": {
    "clean-library-results": {"path": "ui-evidence.json", "sha256": "FILE_SHA256"},
    "privacy-declaration": {"path": "privacy-proof.png", "sha256": "FILE_SHA256"}
  },
  "reviewers": [
    {"reviewer": "product-reviewer", "role": "product", "report": {"path": "product-review.json", "sha256": "FILE_SHA256"}},
    {"reviewer": "compliance-reviewer", "role": "compliance", "report": {"path": "compliance-review.json", "sha256": "FILE_SHA256"}}
  ],
  "ui_runs": [
    {"family": "iphone", "production": true, "result": "/absolute/path/production-iphone.xcresult", "capture_receipt": {"path": "/absolute/path/production-run/review.json", "sha256": "FILE_SHA256"}},
    {"family": "ipad", "production": true, "result": "/absolute/path/production-ipad.xcresult", "capture_receipt": {"path": "/absolute/path/production-run/review.json", "sha256": "FILE_SHA256"}},
    {"family": "iphone", "result": "/absolute/path/iphone.xcresult", "capture_receipt": {"path": "iphone-acceptance.json", "sha256": "FILE_SHA256"}},
    {"family": "ipad", "result": "/absolute/path/ipad.xcresult", "capture_receipt": {"path": "ipad-acceptance.json", "sha256": "FILE_SHA256"}}
  ],
  "screenshots": [
    {"apple_id": "EXACT_APPLE_SCREENSHOT_ID", "path": "/absolute/path/capture.png", "sha256": "FILE_SHA256"}
  ],
  "remediation": []
}
```

Include every uploaded screenshot, using the IDs in `review-context.json`.
The gate verifies local SHA-256 and Apple's MD5 source-file checksum against the
exact pixels, rather than trusting file names. Each UI capture receipt must
contain `app_source_sha256`, `result`, and `simulator_deleted: true`. The gate
reads actual XCTest case results from each retained `.xcresult` with
`xcresulttool`; missing, failed, and skipped cases are rejected. Both iPhone and
iPad must cover the primary card journey, media authoring/picker permissions,
and every required regression identified in Apple's rejection evidence. In
addition, run `python3 Scripts/review-ios-app.py` and cite its `review.json`
directly with `production: true` for each device result. This gate checks Release
optimization, no injected launch arguments/environment or seeded fixtures, fresh
installation, actual Simulator identity, cleanup, retained executable/xctestrun
checksums, and the exact
`MobileProductionReviewJourneyUITests/testCleanInstallCreateStudyAndPersistenceWithoutFixtures`
case. Fixture-based parity cases cannot substitute for that production journey.

### Rejected submissions and metadata-only fixes

Preserve Apple's original written rejection and account evidence in
`.build/ios-review-rejection/`. The default `rejection.json` must include
`version_id`, `submission_id`, `issues` (each with unique `id`, `guideline`, exact
`message`, and `required_tests` XCTest identifiers), and `apple_evidence` (each
with `path` and `sha256`). Use `--rejection-evidence` for another retained file.
Do not invent the rejection reason or treat the bare `REJECTED` state as its
explanation. The internal-review `remediation` array must cover every issue
with `issue_id`, concrete `detail`, and `evidence_ids`. Regression identifiers
use `Suite/testMethod`, without the trailing parentheses.

If only listing text or the test harness changes, preserve the existing valid
binary instead of uploading it again:

```bash
./Scripts/release-ios.sh review-context --reuse-build-from /absolute/path/original-candidate
./Scripts/release-ios.sh submit --reuse-build-from /absolute/path/original-candidate
```

This creates a new review receipt for the current source. Reuse is limited to
`status`, `review-context`, and `submit`; it requires identical production inputs
and matching original source manifest, archive, IPA, delivery receipt, and Apple
build identity. A production code/resource/project change requires a new build.
New review evidence and current UI regressions are still mandatory.

Resolve rejected items in App Store Connect after completing remediation. The
command refuses unresolved rejected items (including rejected sibling items), ambiguous active submissions, and
duplicate submissions. It reuses the one resolved draft and safely resumes an
empty owned draft after interruption. A parent submission may remain in
`UNRESOLVED_ISSUES` after item resolution; resubmission is allowed only when all
its items are ready, accepted, removed, or explicitly resolved. An already waiting, in-review, approved,
or published version is observed without creating another submission. Keep the
submission-time internal-review context and receipt for audit.

Store API credentials outside the repository in
`~/Library/Application Support/NeoAnki2 Signing/app-store-connect.json`:

```json
{
  "team_id": "637635WK8L",
  "app_id": "6818741196",
  "key_id": "YOUR_KEY_ID",
  "issuer_id": "YOUR_ISSUER_ID",
  "private_key_path": "/absolute/path/to/AuthKey_YOUR_KEY_ID.p8"
}
```

Use `--config` for another local path. The key is used only against Apple's
official API and upload tool; private keys and authentication tokens must never
be committed or printed. The initial app record, API access agreement, App
Privacy declaration, and account compliance are managed through App Store
Connect's website where necessary. API credential creation and agreement
acceptance require the applicable computer-use confirmation.

Before `submit`, place `acceptance.json` in the release artifact directory with
the receipt's `source_sha256` and Apple's `build_id`. Include
`production_cloudkit`, `two_device_sync`, `widgets`, `reminders`,
`testflight_install`, and `ios_ui`; each is an object containing `passed: true`,
an `evidence_file` relative to that directory, and the file's `sha256`. Record
only checks actually performed on this candidate. Simulator/mock sync checks
do not replace production CloudKit or physical-device acceptance.

If the release owner explicitly authorizes publication after being informed of
unavailable physical checks, `submit --allow-physical-test-waivers` permits only
the two-device, widget, reminder, and TestFlight-install checks to be waived.
Keep those entries `passed: false`, add `waived: true` and a concrete `reason`,
and retain checksummed evidence describing the gap. Add `waiver_authorization`
with the owner's `user_message` and `known_incomplete_checks` list. The receipt
records passed and waived checks separately. Production schema and UI evidence
remain mandatory. The default command rejects all waived checks.

Store listing text is maintained in `Platforms/iOS/AppStore/en-US.json`.
Screenshot capture creates five images each for iPhone and iPad using uniquely
named disposable Simulators, records XCTest results and image checksums, and
deletes those devices even on failure. It never uses personal study libraries.

1. Run `swift test --parallel` and `bash Scripts/validate-architecture.sh`.
2. Run `bash Scripts/validate-xcode-build-paths.sh`.
3. Run `Scripts/build-ios.sh` for an unsigned simulator build. On a machine
   without an installed Simulator runtime, set `NEOANKI_SKIP_ASSETS=1`; CI must
   run the normal asset-catalog build.
4. Build `NeoAnkiiOS` in Release for `generic/platform=iOS` with signing
   disabled, then validate the application and embedded widget products.
5. Run iPhone SE/large iPhone/iPad UI journeys in portrait and landscape,
   light/dark, accessibility Dynamic Type, Reduce Motion, and Increased Contrast.

## Apple team provisioning

- Register `com.neoanki2.ios` and `com.neoanki2.ios.widget`.
- Register App Group `group.com.neoanki2.shared` and attach both targets.
- Create `iCloud.com.neoanki2.app`, enable private CloudKit, and attach the app.
- Enable push notifications and Background Tasks for the app identifier.
- Deploy the verified CloudKit schema from Development to Production.
- Create App Store distribution profiles for the app and widget and grant the
  release team access to the App Store Connect record.

## Functional release acceptance

- Install signed builds on two physical devices signed into different test
  iCloud accounts. Opt each device in independently; verify the pre-upload
  backup, offline edits, first merge, mutable conflict recovery, immutable
  review union, media transfer, push-triggered sync, and restart recovery.
- Verify reminders are requested only after opt-in and are removed when the
  selected scope has no due cards.
- Verify all widget families show only aggregate due information and deep-link
  into the chosen scope.
- Archive the app, validate it in Organizer/App Store Connect, export with
  `Platforms/iOS/ExportOptions.plist`, upload to TestFlight, and complete an
  internal tester install.

The signed two-device CloudKit test and TestFlight upload are the only expected
external blockers until a paid Apple Developer team is available.
